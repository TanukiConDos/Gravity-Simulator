// Minimal SPIR-V reflection.
//
// Parses just enough of a SPIR-V binary to describe the programmable interface
// of a shader: entry point, stage inputs/outputs, descriptor bindings and push
// constants. It makes no Vulkan calls; vendor:vulkan is used only for its enums
// so the result can be consumed directly by the renderer.
package spirv

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "vendor:vulkan"

MAGIC :: 0x07230203

// -----------------------------------------------------------------------------
// Public result
// -----------------------------------------------------------------------------

Stage :: enum u8 {
	Unknown,
	Vertex,
	Tessellation_Control,
	Tessellation_Evaluation,
	Geometry,
	Fragment,
	Compute,
}

// A stage input/output interface variable. `format` is derived from its SPIR-V
// type; `supported` is false when the type has no vertex attribute equivalent
// (e.g. a matrix or a 64-bit scalar).
Input :: struct {
	name:      string,
	location:  u32,
	component: u32,
	builtin:   bool,
	format:    vulkan.Format,
	supported: bool,
}

// A shader resource. `array_count` is 0 for runtime (unsized) arrays.
Descriptor :: struct {
	name:        string,
	set:         u32,
	binding:     u32,
	descriptor:  vulkan.DescriptorType,
	array_count: u32,
	stage:       vulkan.ShaderStageFlag,
}

Push_Constant :: struct {
	name:   string,
	offset: u32,
	size:   u32,
	stage:  vulkan.ShaderStageFlag,
}

Reflection :: struct {
	entry_point:    string,
	stage:          Stage,
	inputs:         []Input,
	outputs:        []Input,
	descriptors:    []Descriptor,
	push_constants: []Push_Constant,

	allocator: mem.Allocator,
}

stage_flag :: proc(stage: Stage) -> vulkan.ShaderStageFlag {
	switch stage {
	case .Vertex:                  return .VERTEX
	case .Tessellation_Control:    return .TESSELLATION_CONTROL
	case .Tessellation_Evaluation: return .TESSELLATION_EVALUATION
	case .Geometry:                return .GEOMETRY
	case .Fragment:                return .FRAGMENT
	case .Compute:                 return .COMPUTE
	case .Unknown:                 return .VERTEX
	}
	return .VERTEX
}

// reflect parses `code` into a Reflection allocated with the supplied allocator.
// Release it with reflection_destroy.
reflect_with_allocator :: proc(code: []byte, allocator: mem.Allocator) -> (result: Reflection, ok: bool) {
	if len(code) < 5 * 4 || len(code) % 4 != 0 {
		log.errorf("[SPIRV] Invalid module size (%d bytes)", len(code))
		return {}, false
	}
	words := mem.slice_data_cast([]u32, code)
	if words[0] != MAGIC {
		log.errorf("[SPIRV] Bad magic 0x%08X", words[0])
		return {}, false
	}

	parser := _Parser{allocator = allocator}
	defer _parser_destroy(&parser)

	i := 5
	for i < len(words) {
		word := words[i]
		word_count := int(word >> 16)
		opcode := u16(word & 0xFFFF)
		if word_count < 1 || i + word_count > len(words) {
			log.errorf("[SPIRV] Truncated instruction at word %d", i)
			return {}, false
		}
		if !_parse_instruction(&parser, opcode, words[i + 1:i + word_count]) {
			return {}, false
		}
		i += word_count
	}

	return _build(&parser, allocator), true
}

reflect :: proc(code: []byte) -> (Reflection, bool) {
	return reflect_with_allocator(code, context.allocator)
}

reflection_destroy :: proc(self: ^Reflection) {
	if self == nil {return}
	allocator := self.allocator
	_free_io(self.inputs, allocator)
	_free_io(self.outputs, allocator)
	for i in 0 ..< len(self.descriptors) {delete(self.descriptors[i].name, allocator)}
	delete(self.descriptors, allocator)
	for i in 0 ..< len(self.push_constants) {delete(self.push_constants[i].name, allocator)}
	delete(self.push_constants, allocator)
	delete(self.entry_point, allocator)
	self^ = {}
}

@(private)
_free_io :: proc(items: []Input, allocator: mem.Allocator) {
	for i in 0 ..< len(items) {delete(items[i].name, allocator)}
	delete(items, allocator)
}

// _compact copies a dynamic array into an exact-size slice so the reflection
// can free it later with the right size, then releases the scratch array.
@(private)
_compact :: proc(items: ^[dynamic]$T, allocator: mem.Allocator) -> []T {
	result := make([]T, len(items^), allocator)
	copy(result, items^[:])
	delete(items^)
	return result
}

// -----------------------------------------------------------------------------
// Parser state
// -----------------------------------------------------------------------------

@(private)
_Type_Kind :: enum u8 {
	Unknown,
	Void,
	Bool,
	Float,
	Int,
	Vector,
	Matrix,
	Array,
	Runtime_Array,
	Struct,
	Pointer,
	Image,
	Sampler,
	Sampled_Image,
}

@(private)
_Type :: struct {
	kind:    _Type_Kind,
	width:   u16,
	signed:  bool,
	elem:    u32,
	count:   u32,
	members: []u32,
	storage: u32,
	dim:     u32,
	sampled: u32,
}

@(private)
_Variable :: struct {
	id:      u32,
	type:    u32,
	storage: u32,
}

@(private)
_Decoration :: struct {
	id:        u32,
	member:    u32,
	kind:      u32,
	args:      [2]u32,
	argc:      u8,
	is_member: bool,
}

@(private)
_Entry :: struct {
	id:    u32,
	model: u32,
	name:  string,
}

@(private)
_Parser :: struct {
	allocator:   mem.Allocator,
	types:       map[u32]_Type,
	constants:   map[u32]u32,
	names:       map[u32]string,
	decorations: [dynamic]_Decoration,
	variables:   [dynamic]_Variable,
	entries:     [dynamic]_Entry,
}

@(private)
_parser_destroy :: proc(self: ^_Parser) {
	for _, t in self.types {
		if t.members != nil {delete(t.members, self.allocator)}
	}
	delete(self.types)
	delete(self.constants)
	for _, name in self.names {
		if len(name) > 0 {delete(name, self.allocator)}
	}
	delete(self.names)
	delete(self.decorations)
	delete(self.variables)
	for entry in self.entries {
		if len(entry.name) > 0 {delete(entry.name, self.allocator)}
	}
	delete(self.entries)
}

// -----------------------------------------------------------------------------
// SPIR-V opcodes, decorations, storage classes and execution models
// -----------------------------------------------------------------------------

@(private) OP_ENTRY_POINT        :: u16(15)
@(private) OP_NAME               :: u16(5)
@(private) OP_MEMBER_NAME        :: u16(6)
@(private) OP_DECORATE           :: u16(71)
@(private) OP_MEMBER_DECORATE    :: u16(72)
@(private) OP_TYPE_VOID          :: u16(19)
@(private) OP_TYPE_BOOL          :: u16(20)
@(private) OP_TYPE_INT           :: u16(21)
@(private) OP_TYPE_FLOAT         :: u16(22)
@(private) OP_TYPE_VECTOR        :: u16(23)
@(private) OP_TYPE_MATRIX        :: u16(24)
@(private) OP_TYPE_IMAGE         :: u16(25)
@(private) OP_TYPE_SAMPLER       :: u16(26)
@(private) OP_TYPE_SAMPLED_IMAGE :: u16(27)
@(private) OP_TYPE_ARRAY         :: u16(28)
@(private) OP_TYPE_RUNTIME_ARRAY :: u16(29)
@(private) OP_TYPE_STRUCT        :: u16(30)
@(private) OP_TYPE_POINTER       :: u16(32)
@(private) OP_CONSTANT           :: u16(43)
@(private) OP_CONSTANT_TRUE      :: u16(41)
@(private) OP_CONSTANT_FALSE     :: u16(42)
@(private) OP_VARIABLE           :: u16(59)

@(private) DEC_BLOCK          :: u32(2)
@(private) DEC_MATRIX_STRIDE  :: u32(7)
@(private) DEC_BUILT_IN       :: u32(11)
@(private) DEC_LOCATION       :: u32(30)
@(private) DEC_COMPONENT      :: u32(31)
@(private) DEC_BINDING        :: u32(33)
@(private) DEC_DESCRIPTOR_SET :: u32(34)
@(private) DEC_OFFSET         :: u32(35)

@(private) STORAGE_UNIFORM_CONSTANT :: u32(0)
@(private) STORAGE_INPUT           :: u32(1)
@(private) STORAGE_UNIFORM         :: u32(2)
@(private) STORAGE_OUTPUT          :: u32(3)
@(private) STORAGE_PUSH_CONSTANT   :: u32(9)
@(private) STORAGE_STORAGE_BUFFER  :: u32(12)

@(private) DIM_BUFFER :: u32(5)
@(private) IMAGE_SAMPLED_STORAGE :: u32(2)

// -----------------------------------------------------------------------------
// Instruction decoding
// -----------------------------------------------------------------------------

@(private)
_parse_instruction :: proc(p: ^_Parser, opcode: u16, ops: []u32) -> bool {
	switch opcode {
	case OP_ENTRY_POINT:
		if len(ops) < 2 {return false}
		name, _ := _read_string(ops[2:], p.allocator)
		append(&p.entries, _Entry{model = ops[0], id = ops[1], name = name})

	case OP_NAME:
		if len(ops) < 2 {return false}
		name, _ := _read_string(ops[1:], p.allocator)
		p.names[ops[0]] = name

	case OP_MEMBER_NAME:
		// Member names are only used for diagnostics; ignore them.

	case OP_DECORATE:
		if len(ops) < 2 {return false}
		d := _Decoration{id = ops[0], kind = ops[1]}
		d.argc = u8(min(len(ops) - 2, len(d.args)))
		for i in 0 ..< int(d.argc) {d.args[i] = ops[2 + i]}
		append(&p.decorations, d)

	case OP_MEMBER_DECORATE:
		if len(ops) < 3 {return false}
		d := _Decoration{id = ops[0], member = ops[1], kind = ops[2], is_member = true}
		d.argc = u8(min(len(ops) - 3, len(d.args)))
		for i in 0 ..< int(d.argc) {d.args[i] = ops[3 + i]}
		append(&p.decorations, d)

	case OP_TYPE_VOID:
		if len(ops) < 1 {return false}
		p.types[ops[0]] = _Type{kind = .Void}

	case OP_TYPE_BOOL:
		if len(ops) < 1 {return false}
		p.types[ops[0]] = _Type{kind = .Bool}

	case OP_TYPE_INT:
		if len(ops) < 3 {return false}
		p.types[ops[0]] = _Type{kind = .Int, width = u16(ops[1]), signed = ops[2] != 0}

	case OP_TYPE_FLOAT:
		if len(ops) < 2 {return false}
		p.types[ops[0]] = _Type{kind = .Float, width = u16(ops[1])}

	case OP_TYPE_VECTOR:
		if len(ops) < 3 {return false}
		p.types[ops[0]] = _Type{kind = .Vector, elem = ops[1], count = ops[2]}

	case OP_TYPE_MATRIX:
		if len(ops) < 3 {return false}
		p.types[ops[0]] = _Type{kind = .Matrix, elem = ops[1], count = ops[2]}

	case OP_TYPE_ARRAY:
		if len(ops) < 3 {return false}
		p.types[ops[0]] = _Type{kind = .Array, elem = ops[1], count = _constant(p, ops[2])}

	case OP_TYPE_RUNTIME_ARRAY:
		if len(ops) < 2 {return false}
		p.types[ops[0]] = _Type{kind = .Runtime_Array, elem = ops[1]}

	case OP_TYPE_STRUCT:
		members := make([]u32, len(ops) - 1, p.allocator)
		copy(members, ops[1:])
		p.types[ops[0]] = _Type{kind = .Struct, members = members}

	case OP_TYPE_POINTER:
		if len(ops) < 3 {return false}
		p.types[ops[0]] = _Type{kind = .Pointer, storage = ops[1], elem = ops[2]}

	case OP_TYPE_IMAGE:
		if len(ops) < 7 {return false}
		p.types[ops[0]] = _Type{kind = .Image, elem = ops[1], dim = ops[2], sampled = ops[6]}

	case OP_TYPE_SAMPLER:
		if len(ops) < 1 {return false}
		p.types[ops[0]] = _Type{kind = .Sampler}

	case OP_TYPE_SAMPLED_IMAGE:
		if len(ops) < 2 {return false}
		p.types[ops[0]] = _Type{kind = .Sampled_Image, elem = ops[1]}

	case OP_CONSTANT:
		if len(ops) < 3 {return false}
		p.constants[ops[1]] = ops[2]

	case OP_CONSTANT_TRUE:
		if len(ops) < 2 {return false}
		p.constants[ops[1]] = 1

	case OP_CONSTANT_FALSE:
		if len(ops) < 2 {return false}
		p.constants[ops[1]] = 0

	case OP_VARIABLE:
		if len(ops) < 3 {return false}
		append(&p.variables, _Variable{type = ops[0], id = ops[1], storage = ops[2]})

	case:
		// Instructions the reflection does not need are skipped verbatim.
	}
	return true
}

// _read_string decodes a null-terminated SPIR-V literal string starting at the
// first word of `ops`, returning the string and how many words it spans.
@(private)
_read_string :: proc(ops: []u32, allocator: mem.Allocator) -> (str: string, words: int) {
	if len(ops) == 0 {return "", 0}
	bytes := make([dynamic]u8, 0, 16, context.temp_allocator)
	defer delete(bytes)

	done := false
	for i in 0 ..< len(ops) {
		word := ops[i]
		for byte_index in 0 ..< 4 {
			c := u8(word >> (u32(byte_index) * 8))
			if c == 0 {
				done = true
				break
			}
			append(&bytes, c)
		}
		words = i + 1
		if done {break}
	}
	return strings.clone(string(bytes[:]), allocator), words
}

// -----------------------------------------------------------------------------
// Decoration and type helpers
// -----------------------------------------------------------------------------

@(private)
_has_decoration :: proc(p: ^_Parser, id, kind, member: u32, is_member: bool) -> bool {
	for d in p.decorations {
		if d.id == id && d.kind == kind && d.is_member == is_member && d.member == member {
			return true
		}
	}
	return false
}

@(private)
_decoration_arg :: proc(p: ^_Parser, id, kind: u32, arg: int, member: u32 = 0, is_member := false) -> u32 {
	for d in p.decorations {
		if d.id == id && d.kind == kind && d.is_member == is_member && d.member == member {
			if int(d.argc) > arg {return d.args[arg]}
			return 0
		}
	}
	return 0
}

@(private)
_constant :: proc(p: ^_Parser, id: u32) -> u32 {
	if value, ok := p.constants[id]; ok {return value}
	return 0
}

@(private)
_stage_from_model :: proc(model: u32) -> Stage {
	switch model {
	case 0: return .Vertex
	case 1: return .Tessellation_Control
	case 2: return .Tessellation_Evaluation
	case 3: return .Geometry
	case 4: return .Fragment
	case 5: return .Compute
	case:   return .Unknown
	}
	return .Unknown
}

@(private)
_input_less :: proc(a, b: Input) -> bool {
	if a.location != b.location {return a.location < b.location}
	return a.component < b.component
}

// _resolve_format maps a SPIR-V type to the vertex attribute format it
// describes. Matrices, arrays and unusual widths report `false`.
@(private)
_resolve_format :: proc(p: ^_Parser, id: u32) -> (vulkan.Format, bool) {
	t, ok := p.types[id]
	if !ok {return .UNDEFINED, false}

	components := u8(1)
	scalar_id := id
	if t.kind == .Vector {
		if t.count < 2 || t.count > 4 {return .UNDEFINED, false}
		components = u8(t.count)
		scalar_id = t.elem
	}

	scalar, scalar_ok := p.types[scalar_id]
	if !scalar_ok {return .UNDEFINED, false}
	#partial switch scalar.kind {
	case .Float: return format_of_float(components, scalar.width)
	case .Int:   return format_of_int(components, scalar.width, scalar.signed)
	}
	return .UNDEFINED, false
}

// format_of_float maps a float vector of `components` lanes and `width` bits to
// its Vulkan attribute format. Shared with the CPU-side layout validation.
format_of_float :: proc(components: u8, width: u16) -> (vulkan.Format, bool) {
	switch width {
	case 16:
		switch components {
		case 1: return .R16_SFLOAT, true
		case 2: return .R16G16_SFLOAT, true
		case 3: return .R16G16B16_SFLOAT, true
		case 4: return .R16G16B16A16_SFLOAT, true
		}
	case 32:
		switch components {
		case 1: return .R32_SFLOAT, true
		case 2: return .R32G32_SFLOAT, true
		case 3: return .R32G32B32_SFLOAT, true
		case 4: return .R32G32B32A32_SFLOAT, true
		}
	case 64:
		switch components {
		case 1: return .R64_SFLOAT, true
		case 2: return .R64G64_SFLOAT, true
		case 3: return .R64G64B64_SFLOAT, true
		case 4: return .R64G64B64A64_SFLOAT, true
		}
	}
	return .UNDEFINED, false
}

// format_of_int maps an integer vector of `components` lanes and `width` bits to
// its Vulkan attribute format. Shared with the CPU-side layout validation.
format_of_int :: proc(components: u8, width: u16, signed: bool) -> (vulkan.Format, bool) {
	if signed {
		switch width {
		case 8:
			switch components {
			case 1: return .R8_SINT, true
			case 2: return .R8G8_SINT, true
			case 3: return .R8G8B8_SINT, true
			case 4: return .R8G8B8A8_SINT, true
			}
		case 16:
			switch components {
			case 1: return .R16_SINT, true
			case 2: return .R16G16_SINT, true
			case 3: return .R16G16B16_SINT, true
			case 4: return .R16G16B16A16_SINT, true
			}
		case 32:
			switch components {
			case 1: return .R32_SINT, true
			case 2: return .R32G32_SINT, true
			case 3: return .R32G32B32_SINT, true
			case 4: return .R32G32B32A32_SINT, true
			}
		case 64:
			switch components {
			case 1: return .R64_SINT, true
			case 2: return .R64G64_SINT, true
			case 3: return .R64G64B64_SINT, true
			case 4: return .R64G64B64A64_SINT, true
			}
		}
	} else {
		switch width {
		case 8:
			switch components {
			case 1: return .R8_UINT, true
			case 2: return .R8G8_UINT, true
			case 3: return .R8G8B8_UINT, true
			case 4: return .R8G8B8A8_UINT, true
			}
		case 16:
			switch components {
			case 1: return .R16_UINT, true
			case 2: return .R16G16_UINT, true
			case 3: return .R16G16B16_UINT, true
			case 4: return .R16G16B16A16_UINT, true
			}
		case 32:
			switch components {
			case 1: return .R32_UINT, true
			case 2: return .R32G32_UINT, true
			case 3: return .R32G32B32_UINT, true
			case 4: return .R32G32B32A32_UINT, true
			}
		case 64:
			switch components {
			case 1: return .R64_UINT, true
			case 2: return .R64G64_UINT, true
			case 3: return .R64G64B64_UINT, true
			case 4: return .R64G64B64A64_UINT, true
			}
		}
	}
	return .UNDEFINED, false
}

@(private)
_descriptor_type :: proc(p: ^_Parser, base: u32, storage: u32) -> (vulkan.DescriptorType, bool) {
	t, ok := p.types[base]
	if !ok {return .UNIFORM_BUFFER, false}

	switch storage {
	case STORAGE_UNIFORM:
		if t.kind == .Struct && _has_decoration(p, base, DEC_BLOCK, 0, false) {
			return .UNIFORM_BUFFER, true
		}
		return .UNIFORM_BUFFER, true

	case STORAGE_STORAGE_BUFFER:
		return .STORAGE_BUFFER, true

	case STORAGE_UNIFORM_CONSTANT:
		#partial switch t.kind {
		case .Sampled_Image:
			return .COMBINED_IMAGE_SAMPLER, true
		case .Sampler:
			return .SAMPLER, true
		case .Image:
			if t.dim == DIM_BUFFER {
				if t.sampled == IMAGE_SAMPLED_STORAGE {return .STORAGE_TEXEL_BUFFER, true}
				return .UNIFORM_TEXEL_BUFFER, true
			}
			if t.sampled == IMAGE_SAMPLED_STORAGE {return .STORAGE_IMAGE, true}
			return .SAMPLED_IMAGE, true
		}
	}
	return .UNIFORM_BUFFER, false
}

// _type_size approximates the std430 size of a type. Only used to report push
// constant block sizes; member offsets take precedence when present.
@(private)
_type_size :: proc(p: ^_Parser, id: u32) -> u32 {
	t, ok := p.types[id]
	if !ok {return 0}
	#partial switch t.kind {
	case .Bool:
		return 4
	case .Float, .Int:
		return u32(t.width / 8)
	case .Vector:
		return _type_size(p, t.elem) * t.count
	case .Matrix:
		return _type_size(p, t.elem) * t.count
	case .Array:
		return _type_size(p, t.elem) * t.count
	case .Struct:
		_, size := _struct_range(p, id)
		return size
	}
	return 0
}

@(private)
_struct_range :: proc(p: ^_Parser, id: u32) -> (offset: u32, size: u32) {
	t, ok := p.types[id]
	if !ok || t.kind != .Struct {return 0, 0}
	for member, i in t.members {
		member_size := _type_size(p, member)
		member_offset := _decoration_arg(p, id, DEC_OFFSET, 0, u32(i), true)
		if member_offset == 0 && i > 0 {member_offset = offset}
		end := member_offset + member_size
		if end > size {size = end}
		offset = end
	}
	return offset, size
}

// -----------------------------------------------------------------------------
// Result building
// -----------------------------------------------------------------------------

@(private)
_build :: proc(p: ^_Parser, allocator: mem.Allocator) -> Reflection {
	inputs := make([dynamic]Input, 0, 8, allocator)
	outputs := make([dynamic]Input, 0, 8, allocator)
	descriptors := make([dynamic]Descriptor, 0, 8, allocator)
	push_constants := make([dynamic]Push_Constant, 0, 4, allocator)

	stage := Stage.Unknown
	stage_bit := vulkan.ShaderStageFlag.VERTEX
	if len(p.entries) > 0 {
		stage = _stage_from_model(p.entries[0].model)
		stage_bit = stage_flag(stage)
	}

	for v in p.variables {
		pointer, pointer_ok := p.types[v.type]
		if !pointer_ok || pointer.kind != .Pointer {continue}

		switch v.storage {
		case STORAGE_INPUT, STORAGE_OUTPUT:
			builtin := _has_decoration(p, v.id, DEC_BUILT_IN, 0, false)
			if builtin {continue}
			if !_has_decoration(p, v.id, DEC_LOCATION, 0, false) {continue}

			format, supported := _resolve_format(p, pointer.elem)
			item := Input{
				name      = strings.clone(p.names[v.id], allocator),
				location  = _decoration_arg(p, v.id, DEC_LOCATION, 0),
				component = _decoration_arg(p, v.id, DEC_COMPONENT, 0),
				builtin   = builtin,
				format    = format,
				supported = supported,
			}
			if v.storage == STORAGE_INPUT {append(&inputs, item)} else {append(&outputs, item)}

		case STORAGE_UNIFORM, STORAGE_UNIFORM_CONSTANT, STORAGE_STORAGE_BUFFER:
			base := pointer.elem
			array_count := u32(1)
			for {
				array_type, array_ok := p.types[base]
				if !array_ok {break}
				if array_type.kind == .Array {
					if array_type.count > 0 {array_count *= array_type.count} else {array_count = 0}
					base = array_type.elem
				} else if array_type.kind == .Runtime_Array {
					array_count = 0
					base = array_type.elem
				} else {
					break
				}
			}

			descriptor, descriptor_ok := _descriptor_type(p, base, v.storage)
			if !descriptor_ok {continue}

			append(&descriptors, Descriptor{
				name        = strings.clone(p.names[v.id], allocator),
				set         = _decoration_arg(p, v.id, DEC_DESCRIPTOR_SET, 0),
				binding     = _decoration_arg(p, v.id, DEC_BINDING, 0),
				descriptor  = descriptor,
				array_count = array_count,
				stage       = stage_bit,
			})

		case STORAGE_PUSH_CONSTANT:
			_, size := _struct_range(p, pointer.elem)
			append(&push_constants, Push_Constant{
				name   = strings.clone(p.names[v.id], allocator),
				offset = 0,
				size   = size,
				stage  = stage_bit,
			})
		}
	}

	slice.sort_by(inputs[:], _input_less)
	slice.sort_by(outputs[:], _input_less)

	return Reflection{
		entry_point    = strings.clone(p.entries[0].name, allocator) if len(p.entries) > 0 else "",
		stage          = stage,
		inputs         = _compact(&inputs, allocator),
		outputs        = _compact(&outputs, allocator),
		descriptors    = _compact(&descriptors, allocator),
		push_constants = _compact(&push_constants, allocator),
		allocator      = allocator,
	}
}
