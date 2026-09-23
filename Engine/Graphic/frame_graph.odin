package graphic

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:vulkan"

// Path to the declarative frame graph, loaded once at renderer init.
@(private)
FRAME_GRAPH_PATH :: "Engine/Graphic/frame_graph.json"

// Data-driven render graph. `frame_graph.json` declares the resources and passes
// of a frame; this module loads it, works out the dependencies and, each frame,
// walks the resulting order emitting the layout transitions and rendering scopes.
// Pass names are bound to recording procs by the renderer through callbacks, so
// the JSON owns the structure and the code owns the draw calls.

// ---- handles ----

@(private)
Fg_Resource_Id :: distinct u32
@(private)
Fg_Pass_Id :: distinct u32

@(private)
Fg_Resource_Kind :: enum {
	texture,
	buffer,
}

@(private)
Fg_Usage_Bit :: enum {
	color,
	depth,
	transfer_src,
	transfer_dst,
	sampled,
	uniform,
}

@(private)
Fg_Usage :: bit_set[Fg_Usage_Bit]

@(private)
Fg_Kind :: enum {
	graphics,
	transfer,
}

@(private)
Fg_Output_Kind :: enum {
	color,
	depth,
	transfer,
}

// ---- parsed definition ----

@(private)
_Fg_Resource_Def :: struct {
	type:     string   `json:"type"`,
	external: string   `json:"external"`,
	format:   string   `json:"format"`,
	scale:    f32      `json:"scale"`,
	size:     int      `json:"size"`,
	usage:    []string `json:"usage"`,
	final:    string   `json:"final"`,
}

@(private)
_Fg_Input_Def :: struct {
	resource: string `json:"resource"`,
	access:   string `json:"access"`,
}

@(private)
_Fg_Output_Def :: struct {
	resource: string `json:"resource"`,
	as:       string `json:"as"`,
	access:   string `json:"access"`,
	load:     string `json:"load"`,
	store:    string `json:"store"`,
	clear:    []f32  `json:"clear"`,
}

@(private)
_Fg_Binding_Def :: struct {
	set:      u32    `json:"set"`,
	binding:  u32    `json:"binding"`,
	resource: string `json:"resource"`,
	type:     string `json:"type"`,
}

@(private)
_Fg_Pass_Def :: struct {
	name:       string           `json:"name"`,
	pipeline:   string           `json:"pipeline"`,
	type:       string           `json:"type"`,
	optional:   bool             `json:"optional"`,
	inputs:     []_Fg_Input_Def  `json:"inputs"`,
	outputs:    []_Fg_Output_Def `json:"outputs"`,
	bindings:   []_Fg_Binding_Def `json:"bindings"`,
	depends_on: []string         `json:"depends_on"`,
}

@(private)
_Fg_Def :: struct {
	resources: map[string]_Fg_Resource_Def `json:"resources"`,
	passes:    []_Fg_Pass_Def              `json:"passes"`,
}

// ---- runtime model ----

@(private)
Fg_Resource :: struct {
	name:         string,
	kind:         Fg_Resource_Kind,
	usage:        Fg_Usage,
	external:     string,
	format:       vulkan.Format,
	scale:        f32,
	size:         int,
	final_layout: vulkan.ImageLayout,
	aspect:       vulkan.ImageAspectFlags,
}

@(private)
Fg_Input :: struct {
	resource: Fg_Resource_Id,
	access:   Fg_Usage_Bit,
}

@(private)
Fg_Output :: struct {
	resource: Fg_Resource_Id,
	kind:     Fg_Output_Kind,
	load:     vulkan.AttachmentLoadOp,
	store:    vulkan.AttachmentStoreOp,
	clear:    vulkan.ClearValue,
}

@(private)
Fg_Binding :: struct {
	set:      u32,
	binding:  u32,
	resource: Fg_Resource_Id,
	usage:    Fg_Usage_Bit,
}

@(private)
Fg_Pass :: struct {
	name:          string,
	kind:          Fg_Kind,
	pipeline_name: string,
	pipeline:      Pipeline_ID,
	optional:      bool,
	frame_pass:    Frame_Pass,
	inputs:        [dynamic]Fg_Input,
	outputs:       [dynamic]Fg_Output,
	bindings:      [dynamic]Fg_Binding,
	deps:          [dynamic]Fg_Pass_Id,
}

// A resource resolved for the current frame: either an imported/transient
// texture or an imported buffer.
@(private)
Fg_Resolved :: struct {
	target:    Render_Target,
	buffer:    vulkan.Buffer,
	is_buffer: bool,
}

@(private)
Fg_Transient :: struct {
	targets: [MAX_FRAMES_IN_FLIGHT]Render_Target,
	created: [MAX_FRAMES_IN_FLIGHT]bool,
}

@(private)
Fg_Resolve_Proc :: #type proc(user: rawptr, name: string, frame: u32, out: ^Fg_Resolved) -> bool

@(private)
Fg_Record_Proc :: #type proc(user: rawptr, fg: ^Frame_Graph, pass: ^Fg_Pass, cmd: vulkan.CommandBuffer, frame: u32)

@(private)
Frame_Graph :: struct {
	gpu:            ^GPU,
	pipelines:      ^Pipeline_Registry,
	resources:      [dynamic]Fg_Resource,
	resource_index: map[string]Fg_Resource_Id,
	passes:         [dynamic]Fg_Pass,
	pass_index:     map[string]Fg_Pass_Id,
	disabled:       map[string]bool,

	// Per-frame execution state, indexed by resource.
	resolved:    [dynamic]Fg_Resolved,
	layout:      [dynamic]vulkan.ImageLayout,
	last_stage:  [dynamic]vulkan.PipelineStageFlags2,
	last_access: [dynamic]vulkan.AccessFlags2,

	transients:       [dynamic]Fg_Transient,
	transient_extent: vulkan.Extent2D,
	transients_valid: bool,

	resolve:      Fg_Resolve_Proc,
	resolve_user: rawptr,
	record:       Fg_Record_Proc,
	record_user:  rawptr,
}

// ---- parsing helpers ----

@(private)
_fg_usage_bit :: proc(name: string) -> (Fg_Usage_Bit, bool) {
	switch name {
	case "color":          return .color, true
	case "depth":          return .depth, true
	case "transfer_src":   return .transfer_src, true
	case "transfer_dst":   return .transfer_dst, true
	case "transfer_read":  return .transfer_src, true
	case "transfer_write": return .transfer_dst, true
	case "sampled":        return .sampled, true
	case "uniform":        return .uniform, true
	}
	return .color, false
}

@(private)
_fg_resource_kind :: proc(name: string) -> (Fg_Resource_Kind, bool) {
	switch name {
	case "texture": return .texture, true
	case "buffer":  return .buffer, true
	}
	return .texture, false
}

@(private)
_fg_format :: proc(name: string) -> (vulkan.Format, bool) {
	switch name {
	case "R32_UINT":            return .R32_UINT, true
	case "R32_SFLOAT":          return .R32_SFLOAT, true
	case "R8G8B8A8_UNORM":      return .R8G8B8A8_UNORM, true
	case "R8G8B8A8_SRGB":       return .R8G8B8A8_SRGB, true
	case "R16G16B16A16_SFLOAT": return .R16G16B16A16_SFLOAT, true
	}
	return {}, false
}

@(private)
_fg_layout :: proc(name: string) -> (vulkan.ImageLayout, bool) {
	switch name {
	case "", "undefined":         return .UNDEFINED, true
	case "present_src":           return .PRESENT_SRC_KHR, true
	case "attachment":            return .ATTACHMENT_OPTIMAL, true
	case "depth_attachment":      return .DEPTH_ATTACHMENT_OPTIMAL, true
	case "transfer_src":          return .TRANSFER_SRC_OPTIMAL, true
	case "transfer_dst":          return .TRANSFER_DST_OPTIMAL, true
	case "shader_read_only":      return .SHADER_READ_ONLY_OPTIMAL, true
	}
	return {}, false
}

@(private)
_fg_load :: proc(name: string) -> (vulkan.AttachmentLoadOp, bool) {
	if name == "" || name == "load" {return .LOAD, true}
	switch name {
	case "clear": return .CLEAR, true
	case "load":  return .LOAD, true
	}
	return {}, false
}

@(private)
_fg_store :: proc(name: string) -> (vulkan.AttachmentStoreOp, bool) {
	switch name {
	case "store":     return .STORE, true
	case "dont_care": return .DONT_CARE, true
	case "none":      return .NONE, true
	}
	return {}, false
}

@(private)
_fg_is_integer_format :: proc(format: vulkan.Format) -> bool {
	return format == .R32_UINT || format == .R32_SINT || format == .R16_UINT || format == .R8_UINT || format == .R32G32_UINT
}

// Clear value from the JSON array, interpreted per attachment kind and format.
@(private)
_fg_clear_value :: proc(kind: Fg_Output_Kind, format: vulkan.Format, clear: []f32) -> vulkan.ClearValue {
	if kind == .depth {
		depth: f32 = 1.0
		stencil: u32 = 0
		if len(clear) >= 1 {depth = clear[0]}
		if len(clear) >= 2 {stencil = u32(clear[1])}
		return vulkan.ClearValue{depthStencil = vulkan.ClearDepthStencilValue{depth = depth, stencil = stencil}}
	}
	c := [4]f32{0, 0, 0, 1}
	for i in 0 ..< min(len(clear), 4) {c[i] = clear[i]}
	if _fg_is_integer_format(format) {
		return vulkan.ClearValue{color = vulkan.ClearColorValue{uint32 = {u32(c[0]), u32(c[1]), u32(c[2]), u32(c[3])}}}
	}
	return vulkan.ClearValue{color = vulkan.ClearColorValue{float32 = c}}
}

// ---- loading ----

@(private)
frame_graph_load :: proc(
	gpu: ^GPU,
	path: string,
	pipelines: ^Pipeline_Registry,
) -> (
	result: Frame_Graph,
	ok: bool,
) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		log.errorf("[FG] Cannot read frame graph %s", path)
		return {}, false
	}
	defer delete(data, context.allocator)

	def: _Fg_Def
	if err := json.unmarshal(data, &def); err != nil {
		log.errorf("[FG] Cannot parse frame graph %s: %v", path, err)
		return {}, false
	}

	fg := Frame_Graph {
		gpu            = gpu,
		pipelines      = pipelines,
		resource_index = make(map[string]Fg_Resource_Id),
		pass_index     = make(map[string]Fg_Pass_Id),
		disabled       = make(map[string]bool),
	}

	// Resources. Names are sorted so the runtime order (and thus barrier order)
	// is deterministic regardless of map iteration order.
	names := make([dynamic]string, 0, len(def.resources))
	for name in def.resources {append(&names, name)}
	slice.sort(names[:])
	for name in names {
		rdef := def.resources[name]
		kind, kind_ok := _fg_resource_kind(rdef.type)
		if !kind_ok {
			log.errorf("[FG] Resource %q has unknown type %q", name, rdef.type)
			return {}, false
		}
		res := Fg_Resource {
			name     = strings.clone(name),
			kind     = kind,
			external = strings.clone(rdef.external),
			scale    = rdef.scale,
			size     = rdef.size,
		}
		if res.scale == 0 {res.scale = 1.0}
		for usage_name in rdef.usage {
			bit, usage_ok := _fg_usage_bit(usage_name)
			if !usage_ok {
				log.errorf("[FG] Resource %q has unknown usage %q", name, usage_name)
				return {}, false
			}
			res.usage += {bit}
		}
		if (rdef.format != "") {
			format, format_ok := _fg_format(rdef.format)
			if !format_ok {
				log.errorf("[FG] Resource %q has unknown format %q", name, rdef.format)
				return {}, false
			}
			res.format = format
		}
		layout, layout_ok := _fg_layout(rdef.final)
		if !layout_ok {
			log.errorf("[FG] Resource %q has unknown final layout %q", name, rdef.final)
			return {}, false
		}
		res.final_layout = layout
		res.aspect = vulkan.ImageAspectFlags{.COLOR}
		if res.kind == .texture && .depth in res.usage {res.aspect = {.DEPTH}}

		append(&fg.resources, res)
		fg.resource_index[res.name] = Fg_Resource_Id(len(fg.resources) - 1)
	}
	delete(names)

	// Passes.
	for pdef in def.passes {
		pass := Fg_Pass {
			name          = strings.clone(pdef.name),
			pipeline_name = strings.clone(pdef.pipeline),
			optional      = pdef.optional,
			inputs        = make([dynamic]Fg_Input),
			outputs       = make([dynamic]Fg_Output),
			bindings      = make([dynamic]Fg_Binding),
			deps          = make([dynamic]Fg_Pass_Id),
		}
		switch pdef.type {
		case "", "graphics": pass.kind = .graphics
		case "transfer":     pass.kind = .transfer
		case:
			log.errorf("[FG] Pass %q has unknown type %q", pdef.name, pdef.type)
			return {}, false
		}
		pass.frame_pass = frame_pass_create(pass.name, 0)

		for idef in pdef.inputs {
			res, found := fg.resource_index[idef.resource]
			if !found {
				log.errorf("[FG] Pass %q input references unknown resource %q", pdef.name, idef.resource)
				return {}, false
			}
			access, access_ok := _fg_usage_bit(idef.access)
			if !access_ok {
				log.errorf("[FG] Pass %q input has unknown access %q", pdef.name, idef.access)
				return {}, false
			}
			append(&pass.inputs, Fg_Input{resource = res, access = access})
		}

		for odef in pdef.outputs {
			res, found := fg.resource_index[odef.resource]
			if !found {
				log.errorf("[FG] Pass %q output references unknown resource %q", pdef.name, odef.resource)
				return {}, false
			}
			output: Fg_Output
			output.resource = res
			switch odef.as {
			case "color":
				if .color not_in fg.resources[res].usage {
					log.errorf("[FG] Resource %q is not declared as a color attachment", odef.resource)
					return {}, false
				}
				output.kind = .color
			case "depth":
				if .depth not_in fg.resources[res].usage {
					log.errorf("[FG] Resource %q is not declared as a depth attachment", odef.resource)
					return {}, false
				}
				output.kind = .depth
			case "":
				output.kind = .transfer
			case:
				log.errorf("[FG] Pass %q output has unknown 'as' %q", pdef.name, odef.as)
				return {}, false
			}
			if output.kind == .color || output.kind == .depth {
				load, load_ok := _fg_load(odef.load)
				if !load_ok {log.errorf("[FG] Pass %q has unknown load %q", pdef.name, odef.load); return {}, false}
				store, store_ok := _fg_store(odef.store)
				if !store_ok {log.errorf("[FG] Pass %q has unknown store %q", pdef.name, odef.store); return {}, false}
				output.load = load
				output.store = store
				output.clear = _fg_clear_value(output.kind, fg.resources[res].format, odef.clear)
			}
			append(&pass.outputs, output)
		}

		for bdef in pdef.bindings {
			res, found := fg.resource_index[bdef.resource]
			if !found {
				log.errorf("[FG] Pass %q binding references unknown resource %q", pdef.name, bdef.resource)
				return {}, false
			}
			usage, usage_ok := _fg_usage_bit(bdef.type)
			if !usage_ok {
				log.errorf("[FG] Pass %q binding has unknown type %q", pdef.name, bdef.type)
				return {}, false
			}
			append(&pass.bindings, Fg_Binding{set = bdef.set, binding = bdef.binding, resource = res, usage = usage})
		}

		// depth state comes from the pass's depth output, if any
		for output in pass.outputs {
			if output.kind == .depth {
				pass.frame_pass.depth_load = output.load
				pass.frame_pass.depth_store = output.store
				pass.frame_pass.depth_clear = output.clear
			}
		}

		append(&fg.passes, pass)
		fg.pass_index[pass.name] = Fg_Pass_Id(len(fg.passes) - 1)
	}

	// Resolve pipelines and validate the static structure once.
	for &pass in fg.passes {
		if pass.kind != .graphics {continue}
		id, found := pipeline_registry_find(pipelines, pass.pipeline_name)
		if !found {
			log.errorf("[FG] Pass %q references unknown pipeline %q", pass.name, pass.pipeline_name)
			return {}, false
		}
		pass.pipeline = id
		pass.frame_pass.pipeline = id
	}

	// One writer per resource, and every dependency edge must exist.
	writer := make([]i32, len(fg.resources))
	defer delete(writer)
	for &w in writer {w = -1}
	for &pass, pi in fg.passes {
		for output in pass.outputs {
			ri := int(output.resource)
			if writer[ri] != -1 {
				log.errorf("[FG] Resource %q is written by more than one pass", fg.resources[ri].name)
				return {}, false
			}
			writer[ri] = i32(pi)
		}
	}
	for &pass, pi in fg.passes {
		for input in pass.inputs {
			_fg_add_dep(&pass, writer, int(input.resource), pi)
		}
		for binding in pass.bindings {
			_fg_add_dep(&pass, writer, int(binding.resource), pi)
		}
	}

	fg.resolved = make([dynamic]Fg_Resolved, len(fg.resources))
	fg.layout = make([dynamic]vulkan.ImageLayout, len(fg.resources))
	fg.last_stage = make([dynamic]vulkan.PipelineStageFlags2, len(fg.resources))
	fg.last_access = make([dynamic]vulkan.AccessFlags2, len(fg.resources))
	fg.transients = make([dynamic]Fg_Transient, len(fg.resources))
	for i in 0 ..< len(fg.transients) {fg.transients[i] = Fg_Transient{}}

	log.infof("[FG] Loaded %d resources and %d passes from %s", len(fg.resources), len(fg.passes), path)
	result = fg
	return result, true
}

@(private)
_fg_add_dep :: proc(pass: ^Fg_Pass, writer: []i32, resource: int, self_index: int) {
	w := writer[resource]
	if w < 0 || int(w) == self_index {return}
	for d in pass.deps {if int(d) == int(w) {return}}
	append(&pass.deps, Fg_Pass_Id(w))
}

@(private)
frame_graph_destroy :: proc(fg: ^Frame_Graph) {
	for &transient in fg.transients {
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			if transient.created[i] {render_target_destroy(&transient.targets[i])}
		}
	}
	for &pass in fg.passes {
		delete(pass.name); delete(pass.pipeline_name)
		delete(pass.inputs); delete(pass.outputs); delete(pass.bindings); delete(pass.deps)
	}
	for &res in fg.resources {delete(res.name); delete(res.external)}
	delete(fg.passes); delete(fg.pass_index)
	delete(fg.resources); delete(fg.resource_index)
	delete(fg.disabled)
	delete(fg.resolved); delete(fg.layout); delete(fg.last_stage); delete(fg.last_access)
	delete(fg.transients)
}

@(private)
fg_set_pass_enabled :: proc(fg: ^Frame_Graph, name: string, enabled: bool) {
	fg.disabled[name] = !enabled
}

@(private)
fg_texture :: proc(fg: ^Frame_Graph, name: string) -> ^Render_Target {
	ri, found := fg.resource_index[name]
	if !found {return nil}
	return &fg.resolved[int(ri)].target
}

@(private)
fg_buffer :: proc(fg: ^Frame_Graph, name: string) -> vulkan.Buffer {
	ri, found := fg.resource_index[name]
	if !found {return 0}
	return fg.resolved[int(ri)].buffer
}

// ---- execution ----

@(private)
_fg_barrier :: proc(
	fg: ^Frame_Graph,
	cmd: vulkan.CommandBuffer,
	resource: Fg_Resource_Id,
	new_layout: vulkan.ImageLayout,
	dst_stage: vulkan.PipelineStageFlags2,
	dst_access: vulkan.AccessFlags2,
) {
	i := int(resource)
	target := fg.resolved[i].target
	if target.image == 0 {return}
	image_barrier(
		cmd,
		target.image,
		fg.resources[i].aspect,
		fg.layout[i],
		new_layout,
		fg.last_stage[i],
		dst_stage,
		fg.last_access[i],
		dst_access,
	)
	fg.layout[i] = new_layout
	fg.last_stage[i] = dst_stage
	fg.last_access[i] = dst_access
}

@(private)
_fg_ensure_transient :: proc(fg: ^Frame_Graph, resource: Fg_Resource_Id, frame: u32, extent: vulkan.Extent2D) -> bool {
	i := int(resource)
	scaled := vulkan.Extent2D {
		width  = max(u32(f32(extent.width) * fg.resources[i].scale), 1),
		height = max(u32(f32(extent.height) * fg.resources[i].scale), 1),
	}
	if fg.transients[i].created[frame] && fg.resolved[i].target.extent == scaled {
		return true
	}
	if fg.transients[i].created[frame] {render_target_destroy(&fg.transients[i].targets[frame])}

	usage: vulkan.ImageUsageFlags
	if .color in fg.resources[i].usage {usage += {.COLOR_ATTACHMENT}}
	if .sampled in fg.resources[i].usage {usage += {.SAMPLED}}
	if .transfer_src in fg.resources[i].usage {usage += {.TRANSFER_SRC}}
	if .transfer_dst in fg.resources[i].usage {usage += {.TRANSFER_DST}}

	target, created := render_target_init(fg.gpu, Render_Target_Desc{
		format = fg.resources[i].format,
		extent = scaled,
		usage  = usage,
		aspect = fg.resources[i].aspect,
	})
	if !created {return false}
	fg.transients[i].targets[frame] = target
	fg.transients[i].created[frame] = true
	return true
}

// frame_graph_execute runs the frame: it culls disabled/unused passes, sorts the
// rest, resolves resources, emits the derived barriers and opens each rendering
// scope around the registered record callback.
@(private)
frame_graph_execute :: proc(
	fg: ^Frame_Graph,
	cmd: vulkan.CommandBuffer,
	frame: u32,
	extent: vulkan.Extent2D,
) -> bool {
	for i in 0 ..< len(fg.resources) {
		fg.layout[i] = .UNDEFINED
		fg.last_stage[i] = {.TOP_OF_PIPE}
		fg.last_access[i] = {}
	}

	// Resolve imports and transients.
	for &res, i in fg.resources {
		if res.external != "" {
			if fg.resolve == nil {continue}
			out: Fg_Resolved
			if !fg.resolve(fg.resolve_user, res.external, frame, &out) {
				log.errorf("[FG] Cannot resolve import %q", res.external)
				return false
			}
			fg.resolved[i] = out
		} else if res.kind == .texture {
			if !_fg_ensure_transient(fg, Fg_Resource_Id(i), frame, extent) {
				log.errorf("[FG] Cannot create transient %q", res.name)
				return false
			}
			fg.resolved[i] = Fg_Resolved{target = fg.transients[i].targets[frame]}
		}
	}

	order, sorted := _fg_order(fg)
	defer delete(order)
	if !sorted {
		log.errorf("[FG] Pass dependencies contain a cycle")
		return false
	}

	for pid in order {
		pass := &fg.passes[int(pid)]

		for input in pass.inputs {
			#partial switch input.access {
			case .transfer_src:
				_fg_barrier(fg, cmd, input.resource, .TRANSFER_SRC_OPTIMAL, {.TRANSFER}, {.TRANSFER_READ})
			case .sampled:
				_fg_barrier(fg, cmd, input.resource, .SHADER_READ_ONLY_OPTIMAL, {.FRAGMENT_SHADER}, {.SHADER_SAMPLED_READ})
			case:
				// Other accesses are not read dependencies.
			}
		}
		for binding in pass.bindings {
			if binding.usage == .sampled {
				_fg_barrier(fg, cmd, binding.resource, .SHADER_READ_ONLY_OPTIMAL, {.FRAGMENT_SHADER}, {.SHADER_SAMPLED_READ})
			}
		}
		for output in pass.outputs {
			switch output.kind {
			case .color:
				_fg_barrier(fg, cmd, output.resource, .ATTACHMENT_OPTIMAL, {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_WRITE})
			case .depth:
				_fg_barrier(fg, cmd, output.resource, .DEPTH_ATTACHMENT_OPTIMAL, {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_STENCIL_ATTACHMENT_WRITE})
			case .transfer:
				// Buffer writes need no image barrier here.
			}
		}

		switch pass.kind {
		case .graphics:
			colors: [MAX_COLOR_ATTACHMENTS]Color_Attachment
			count := 0
			depth: ^Render_Target
			for output in pass.outputs {
				switch output.kind {
				case .color:
					colors[count] = Color_Attachment {
						target = fg.resolved[int(output.resource)].target,
						load   = output.load,
						store  = output.store,
						clear  = output.clear,
					}
					count += 1
				case .depth:
					depth = &fg.resolved[int(output.resource)].target
				case .transfer:
				}
			}
			frame_pass_begin(cmd, &pass.frame_pass, colors[:count], depth, extent)
			pipeline_bind(pipeline_registry_get(fg.pipelines, pass.pipeline), cmd)
			if fg.record != nil {fg.record(fg.record_user, fg, pass, cmd, frame)}
			frame_pass_end(cmd, &pass.frame_pass)
		case .transfer:
			if fg.record != nil {fg.record(fg.record_user, fg, pass, cmd, frame)}
		}
	}

	// Imported textures settle into their declared final layout (e.g. the
	// swapchain image becomes presentable).
	for &res, i in fg.resources {
		if res.kind != .texture || res.final_layout == .UNDEFINED {continue}
		if fg.resolved[i].target.image == 0 {continue}
		_fg_barrier(fg, cmd, Fg_Resource_Id(i), res.final_layout, {.BOTTOM_OF_PIPE}, {})
	}
	return true
}

// _fg_order culls passes whose output nobody consumes and returns a topological
// order of the rest (stable by declaration index).
@(private)
_fg_order :: proc(fg: ^Frame_Graph) -> (order: [dynamic]Fg_Pass_Id, ok: bool) {
	n := len(fg.passes)
	keep := make([]bool, n)
	defer delete(keep)

	for &pass, i in fg.passes {
		if pass.optional && fg.disabled[pass.name] {continue}
		for output in pass.outputs {
			if fg.resources[int(output.resource)].external != "" || fg.resources[int(output.resource)].final_layout != .UNDEFINED {
				keep[i] = true
				break
			}
		}
	}

	changed := true
	for changed {
		changed = false
		for &pass, i in fg.passes {
			if keep[i] {continue}
			for &other, j in fg.passes {
				if !keep[j] {continue}
				for dep in other.deps {
					if int(dep) == i {keep[i] = true; changed = true; break}
				}
				if keep[i] {break}
			}
		}
	}

	indegree := make([]int, n)
	defer delete(indegree)
	for &pass, i in fg.passes {
		if !keep[i] {continue}
		for dep in pass.deps {if keep[int(dep)] {indegree[i] += 1}}
	}

	emitted := make([]bool, n)
	defer delete(emitted)
	for {
		pick := -1
		for i in 0 ..< n {
			if keep[i] && !emitted[i] && indegree[i] == 0 {pick = i; break}
		}
		if pick == -1 {break}
		emitted[pick] = true
		append(&order, Fg_Pass_Id(pick))
		for &other, j in fg.passes {
			if !keep[j] || emitted[j] {continue}
			for dep in other.deps {if int(dep) == pick {indegree[j] -= 1}}
		}
	}

	for i in 0 ..< n {if keep[i] && !emitted[i] {return order, false}}
	return order, true
}
