package graphic

import "base:runtime"
import "core:log"
import "core:strings"
import "vendor:vulkan"
import spirv "./spirv"

@(private)
_Built_Vertex_Input :: struct {
	bindings:   [dynamic]vulkan.VertexInputBindingDescription,
	attributes: [dynamic]vulkan.VertexInputAttributeDescription,
}

// _build_vertex_input pairs every configured vertex buffer with the vertex
// shader's input locations. Bindings are filled in configuration order; each
// struct's attribute fields consume the next locations in ascending order,
// which keeps the layout tied to the shader instead of a hand-written list.
@(private)
_build_vertex_input :: proc(
	cfg: Pipeline_Config,
	inputs: []spirv.Input,
) -> (
	result: _Built_Vertex_Input,
	ok: bool,
) {
	bindings := make([dynamic]vulkan.VertexInputBindingDescription, 0, len(cfg.vertex_buffers))
	attributes := make([dynamic]vulkan.VertexInputAttributeDescription, 0, 8)
	committed := false
	defer if !committed {
		delete(bindings)
		delete(attributes)
	}

	next_input := 0
	for spec in cfg.vertex_buffers {
		info := runtime.type_info_base(type_info_of(spec.type))
		structure, is_struct := info.variant.(runtime.Type_Info_Struct)
		if !is_struct {
			log.errorf("[VULKAN] Vertex buffer %d: %v is not a struct", spec.binding, spec.type)
			return {}, false
		}

		append(&bindings, vulkan.VertexInputBindingDescription{
			binding   = spec.binding,
			stride    = u32(info.size),
			inputRate = spec.input_rate,
		})

		for i in 0 ..< structure.field_count {
			field_name := structure.names[i]
			if strings.has_prefix(field_name, "_") {continue}

			if next_input >= len(inputs) {
				log.errorf(
					"[VULKAN] Vertex buffer %d has more attribute fields than the shader declares inputs",
					spec.binding,
				)
				return {}, false
			}
			input := inputs[next_input]
			next_input += 1

			field_type := structure.types[i]
			expected, supported := _format_from_type(field_type)
			if !supported {
				log.errorf(
					"[VULKAN] Vertex buffer %d field %q has no attribute format for %v",
					spec.binding,
					field_name,
					field_type.id,
				)
				return {}, false
			}
			if expected != input.format {
				log.errorf(
					"[VULKAN] Vertex buffer %d field %q expects %v but shader location %d is %v",
					spec.binding,
					field_name,
					expected,
					input.location,
					input.format,
				)
				return {}, false
			}

			component_size := _component_size_from_type(field_type)
			if component_size > 0 && u32(structure.offsets[i]) % component_size != 0 {
				log.errorf(
					"[VULKAN] Vertex buffer %d field %q is misaligned for %v",
					spec.binding,
					field_name,
					input.format,
				)
				return {}, false
			}

			append(&attributes, vulkan.VertexInputAttributeDescription{
				location = input.location,
				binding  = spec.binding,
				format   = input.format,
				offset   = u32(structure.offsets[i]),
			})
		}
	}

	if next_input != len(inputs) {
		log.errorf(
			"[VULKAN] Shader declares %d vertex inputs but the configured buffers describe %d",
			len(inputs),
			next_input,
		)
		return {}, false
	}

	committed = true
	return _Built_Vertex_Input{bindings = bindings, attributes = attributes}, true
}

// _format_from_type maps an Odin field type to the vertex attribute format the
// shader must declare for it, so a field reorder or type change is caught at
// pipeline build time.
@(private)
_format_from_type :: proc(info: ^runtime.Type_Info) -> (vulkan.Format, bool) {
	base := runtime.type_info_base(info)
	components := u8(1)
	scalar := base

	#partial switch array in base.variant {
	case runtime.Type_Info_Array:
		if array.count < 2 || array.count > 4 {return .UNDEFINED, false}
		components = u8(array.count)
		scalar = runtime.type_info_base(array.elem)
	}

	#partial switch kind in scalar.variant {
	case runtime.Type_Info_Float:
		return spirv.format_of_float(components, u16(scalar.size * 8))
	case runtime.Type_Info_Integer:
		return spirv.format_of_int(components, u16(scalar.size * 8), kind.signed)
	}
	return .UNDEFINED, false
}

@(private)
_component_size_from_type :: proc(info: ^runtime.Type_Info) -> u32 {
	base := runtime.type_info_base(info)
	#partial switch array in base.variant {
	case runtime.Type_Info_Array:
		return u32(array.elem_size)
	}
	return u32(base.size)
}
