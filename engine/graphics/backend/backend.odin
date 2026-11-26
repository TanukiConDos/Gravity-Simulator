package vk

import gfx "engine:graphics/shared"
import found "engine:foundation"
import "core:log"
import "core:sync"
import "core:time"
import "vendor:vulkan"

// Stream_Handle, Stream_Ops, Instance_Stream and InstanceData are the neutral
// stream seam, defined in `shared/gfx.odin` so a producer never imports `vk`.
// The aliases live in `graphic.odin`.

// Backend is the Vulkan side of the renderer: window surface, device, swapchain,
// pipelines, frame graph, compute and the optional GPU gravity solver. The front
// (`graphic`) builds one gfx.Frame_Packet per frame and calls backend_draw; every
// API call, barrier, fence and present stays here.
Backend :: struct {
	window:          ^Window,
	gpu:             GPU,
	command_pool:    CommandPool,
	swapchain:       SwapChain,
	config:          Pipeline_Config,
	pipelines:       Pipeline_Registry,
	main_pipeline:   Pipeline_ID,
	frame_graph:     Frame_Graph,
	push:            Push_Descriptors,
	model:           Model,
	// Direct rendering (M5): when a compute consumer registers a stream producer,
	// the instance data is packed from its buffers and the frame waits on its
	// timeline. The front holds the handle and asks the backend to pump/clear;
	// the backend dispatches through the producer's ops, so it needs no engine
	// types to draw the stream.
	direct_pipeline: Pipeline_ID,
	direct_push:     Push_Descriptors,
	direct_valid:    bool,
	stream:          Instance_Stream,
	stream_handle:   Stream_Handle,
	stream_ops:      Stream_Ops,
	// Frame value the currently held stream was last read at. The producer
	// releases the stream with this value so it waits for that frame before
	// reusing the buffers.
	direct_release_value: u64,
	direct_logged:   bool,
	direct_count:    int,
	// Signals every submitted frame so the producer can keep its render columns
	// stable while this thread reads them (the reverse of the frame's wait on
	// the producer's timeline).
	frame_timeline:  Timeline,
	instances:       InstanceBuffer,
	// The packet being recorded, so the frame-graph callbacks can reach this
	// frame's camera and instance columns.
	packet:          ^gfx.Frame_Packet,
	// The pick ID is a transient owned by the frame graph; the backend only owns
	// the readback buffers and the state used to resolve them.
	frame_color:     Render_Target,
	pick_readback:   [MAX_FRAMES_IN_FLIGHT]Buffer,
	pick_pending:    [MAX_FRAMES_IN_FLIGHT]bool,
	current_frame:   u32,
	// Hot reload: the main thread sets these, the graphics thread consumes them
	// at the top of a frame. Kept out of the frame path until requested.
	shader_reload_requested:      u32,
	frame_graph_reload_requested: u32,
}

// backend_init creates the whole Vulkan side for a window. It reads no engine
// state: the caller seeds the instance columns and supplies any GPU-produced
// stream separately.
backend_init :: proc(window: ^Window) -> (result: ^Backend, ok: bool) {
	self := new(Backend)
	committed := false
	defer if !committed {backend_destroy(self)}

	self.window = window
	log.infof("========================================")
	log.infof("[VULKAN] BACKEND INITIALIZATION START")
	log.infof("========================================")
	self.gpu = gpu_init(window) or_return
	self.command_pool = command_pool_init(&self.gpu) or_return
	self.swapchain = swapchain_init(&self.gpu, window) or_return
	self.config = renderer_pipeline_config()
	self.pipelines = pipeline_registry_init(&self.gpu)
	color_formats := [2]vulkan.Format{self.swapchain.image_format, PICK_COLOR_FORMAT}
	self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, color_formats[:], self.swapchain.depth_format) or_return
	_backend_create_pick_resources(self) or_return
	self.model = model_init(&self.gpu, &self.command_pool, 30, 30) or_return
	self.push = push_descriptors_init(&self.gpu, RENDERER_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(&self.push, pipeline_registry_get(&self.pipelines, self.main_pipeline)) {return nil, false}
	self.frame_timeline = timeline_init(&self.gpu) or_return
	_backend_init_direct(self) or_return
	self.instances = instance_buffer_init(&self.gpu)
	self.frame_graph = frame_graph_load(&self.gpu, FRAME_GRAPH_PATH, &self.pipelines) or_return
	self.frame_graph.resolve = _backend_resolve_import
	self.frame_graph.resolve_user = self
	self.frame_graph.record = _backend_record_pass
	self.frame_graph.record_user = self
	log.infof("========================================")
	log.infof("[VULKAN] BACKEND INITIALIZATION COMPLETE")
	log.infof("========================================")
	committed = true
	return self, true
}

backend_destroy :: proc(self: ^Backend) {
	if self == nil {return}
	log.infof("[VULKAN] Backend shutdown...")
	gpu_wait(&self.gpu)
	timeline_destroy(&self.frame_timeline)
	model_destroy(&self.model); push_descriptors_destroy(&self.push)
	push_descriptors_destroy(&self.direct_push)
	instance_buffer_destroy(&self.instances)
	_backend_destroy_pick_resources(self)
	frame_graph_destroy(&self.frame_graph)
	pipeline_registry_destroy(&self.pipelines); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Backend shutdown complete")
}

// backend_instances_seed fills the static instance columns (radius, selection)
// once. The front converts its body view into these plain columns; the backend
// owns the packed vertex layout and the GPU buffers.
backend_instances_seed :: proc(self: ^Backend, bodies: []u32, radii: []f32, selected: []u8) {
	if self == nil {return}
	instance_buffer_write_static(&self.instances, bodies, radii, selected)
}

// backend_instances_reseed replaces the static columns while frames may still be
// in flight (a hot-reloaded gameplay layer spawned bodies). It waits for the
// frame timeline because `instance_buffer_ensure` may reallocate the buffers.
backend_instances_reseed :: proc(self: ^Backend, bodies: []u32, radii: []f32, selected: []u8) {
	if self == nil {return}
	timeline_wait(&self.frame_timeline, self.frame_timeline.value)
	instance_buffer_write_static(&self.instances, bodies, radii, selected)
}

// backend_set_stream_producer registers the GPU producer the renderer may draw
// from. `handle` is opaque to the backend; `ops` is the producer's dispatch
// table. Installing a new producer releases any stream the backend currently
// holds through the previous producer.
backend_set_stream_producer :: proc(self: ^Backend, handle: Stream_Handle, ops: Stream_Ops) {
	if self == nil {return}
	if self.direct_valid {backend_clear_stream(self)}
	self.stream_handle = handle
	self.stream_ops = ops
	if ops.set_frame_timeline != nil {
		ops.set_frame_timeline(handle, gfx.Semaphore(u64(self.frame_timeline.semaphore)))
	}
}

// backend_pump_stream asks the installed producer for a newly published stream
// and adopts it. The producer returns false while it has nothing new; the backend
// then keeps the stream it already holds. The previous stream is released with
// the last frame value that read it.
backend_pump_stream :: proc(self: ^Backend) -> bool {
	if self == nil || self.stream_ops.claim == nil {return false}
	stream, ok := self.stream_ops.claim(self.stream_handle)
	if !ok {return false}
	if self.direct_valid && self.stream_ops.release != nil {
		self.stream_ops.release(self.stream_handle, self.stream, self.direct_release_value)
	}
	self.stream = stream
	self.direct_valid = true
	self.direct_release_value = 0
	if !self.direct_logged {
		self.direct_logged = true
		log.infof(
			"[RENDER] Direct instances enabled: %d bodies (mode %d, set %d) from the GPU producer",
			stream.count,
			stream.mode,
			stream.set,
		)
	}
	return true
}

// backend_clear_stream releases the held stream through its producer and returns
// to the CPU instance columns.
backend_clear_stream :: proc(self: ^Backend) {
	if self == nil {return}
	if self.direct_valid && self.stream_ops.release != nil {
		self.stream_ops.release(self.stream_handle, self.stream, self.direct_release_value)
	}
	self.direct_valid = false
	self.stream = {}
	self.direct_release_value = 0
	self.direct_logged = false
}

// backend_instance_mode tells the front whether this frame's instance data comes
// from its CPU columns (CPU) or from a GPU producer's stream (BACKEND). The read
// is graphics-thread only, like every field of the frame path.
backend_instance_mode :: proc(self: ^Backend) -> gfx.Instance_Mode {
	if self != nil && self.direct_valid {return .BACKEND}
	return .CPU
}

// backend_request_shader_reload asks the graphics thread to rebuild every
// registered pipeline from the current SPIR-V on its next frame. Safe to call
// from the main thread.
backend_request_shader_reload :: proc(self: ^Backend) {
	if self == nil {return}
	sync.atomic_store(&self.shader_reload_requested, u32(1))
}

// _backend_validate_rebuilt_pipeline checks a freshly built pipeline against the
// push-descriptor interface the renderer has already allocated. A shader that
// changes those bindings is rejected: the live pipeline keeps drawing instead of
// crashing the next frame. Validation mutates the cached stage flags, so a
// failure restores them from the old pipeline.
@(private)
_backend_validate_rebuilt_pipeline :: proc(
	user: rawptr,
	name: string,
	pipeline: ^Pipeline,
) -> bool {
	self := cast(^Backend)user
	switch name {
	case "main":
		if !push_descriptors_validate(&self.push, pipeline) {
			_ = push_descriptors_validate(
				&self.push,
				pipeline_registry_get(&self.pipelines, self.main_pipeline),
			)
			return false
		}
	case "instance_pack":
		if !push_descriptors_validate(&self.direct_push, pipeline) {
			_ = push_descriptors_validate(
				&self.direct_push,
				pipeline_registry_get(&self.pipelines, self.direct_pipeline),
			)
			return false
		}
	}
	return true
}

// _backend_reload_shaders rebuilds the backend's graphics pipelines in place.
// It waits only for the frame timeline the backend itself advances: commands
// that could reference the live handles have completed, while the physics
// thread's compute queue is untouched.
@(private)
_backend_reload_shaders :: proc(self: ^Backend) {
	if sync.atomic_load(&self.shader_reload_requested) == 0 {return}
	sync.atomic_store(&self.shader_reload_requested, u32(0))

	{
		found.profile_scope("graphics.shader_reload")
		timeline_wait(&self.frame_timeline, self.frame_timeline.value)
		rebuilt, failed := pipeline_registry_rebuild_all(
			&self.pipelines,
			_backend_validate_rebuilt_pipeline,
			self,
		)
		if failed > 0 {
			log.errorf(
				"[HOT] Graphics shaders: %d rebuilt, %d kept the previous pipeline",
				rebuilt,
				failed,
			)
		} else {
			log.infof("[HOT] Graphics shaders reloaded (%d pipelines)", rebuilt)
		}
	}
}

// backend_request_frame_graph_reload asks the graphics thread to re-parse
// `frame_graph.json` on its next frame. Safe to call from the main thread.
backend_request_frame_graph_reload :: proc(self: ^Backend) {
	if self == nil {return}
	sync.atomic_store(&self.frame_graph_reload_requested, u32(1))
}

// _backend_validate_frame_graph rejects a reloaded graph that names an import or
// pass this backend has no implementation for, and checks that each external
// resource has the texture/buffer shape its resolver produces.
@(private)
_backend_validate_frame_graph :: proc(fg: ^Frame_Graph) -> bool {
	if fg == nil {return false}
	for &res in fg.resources {
		if len(res.external) == 0 {continue}
		switch res.external {
		case "swapchain", "depth":
			if res.kind != .texture {
				log.errorf("[FG] Import %q must be a texture", res.external)
				return false
			}
		case "pick_readback", "camera":
			if res.kind != .buffer {
				log.errorf("[FG] Import %q must be a buffer", res.external)
				return false
			}
		case:
			log.errorf("[FG] Unknown import %q", res.external)
			return false
		}
	}
	for &pass in fg.passes {
		switch pass.name {
		case "main", "pick_copy":
		case:
			log.errorf("[FG] No recording proc for pass %q", pass.name)
			return false
		}
	}
	return true
}

// _backend_reload_frame_graph swaps in a freshly parsed graph. The old graph owns
// its transients, so it is destroyed only after the frame timeline shows that no
// submitted frame still reads them.
@(private)
_backend_reload_frame_graph :: proc(self: ^Backend) {
	if sync.atomic_load(&self.frame_graph_reload_requested) == 0 {return}
	sync.atomic_store(&self.frame_graph_reload_requested, u32(0))

	timeline_wait(&self.frame_timeline, self.frame_timeline.value)
	next, loaded := frame_graph_load(&self.gpu, FRAME_GRAPH_PATH, &self.pipelines)
	if !loaded {return}
	if !_backend_validate_frame_graph(&next) {
		frame_graph_destroy(&next)
		log.errorf("[HOT] Frame graph reload rejected; keeping the live graph")
		return
	}
	next.resolve = _backend_resolve_import
	next.resolve_user = self
	next.record = _backend_record_pass
	next.record_user = self

	old := self.frame_graph
	self.frame_graph = next
	frame_graph_destroy(&old)
	log.infof(
		"[HOT] Frame graph reloaded (%d resources, %d passes)",
		len(self.frame_graph.resources),
		len(self.frame_graph.passes),
	)
}

// backend_draw runs one frame: resize/acquire, pick resolution, the optional
// direct instance pack, the frame graph, submit and present. A RETRY result
// means no frame slot was consumed; the caller keeps its state and calls again.
backend_draw :: proc(
	self: ^Backend,
	packet: ^gfx.Frame_Packet,
) -> (
	status: gfx.Frame_Status,
	result: gfx.Frame_Result,
) {
	if self == nil || packet == nil {return .FATAL, result}
	self.packet = packet
	defer {self.packet = nil}

	_backend_reload_shaders(self)
	_backend_reload_frame_graph(self)

	if sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
		return .RETRY, result
	}

	_backend_pick_resolve_ready(self, &result)

	frame := self.current_frame
	{
		found.profile_scope("graphics.wait_frame")
		swapchain_wait_for_frame(&self.swapchain, frame)
	}
	_backend_pick_resolve_slot(self, frame, &result)
	_backend_verify_stream(self, frame)

	recreate := false
	acquire_result: vulkan.Result
	image_idx: u32
	{
		found.profile_scope("graphics.acquire")
		acquire_result, image_idx = swapchain_acquire_next(&self.swapchain, frame)
	}
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
		return .RETRY, result
	} else if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return .FATAL, result
	} else if acquire_result == .SUBOPTIMAL_KHR {
		recreate = true
	}
	found.profile_mark("graphics.acquired", "frame=%d image=%d", {frame, image_idx})

	swapchain_prepare_frame(&self.swapchain, frame, image_idx)
	command_pool_reset(&self.command_pool, frame)
	command_buffer := command_pool_begin(&self.command_pool, frame)
	self.frame_color = swapchain_color_target(&self.swapchain, image_idx)
	fg_set_pass_enabled(&self.frame_graph, "pick_copy", packet.pick.requested)
	// The instance pack is compute, so it must be recorded before the render
	// pass begins; the main pass then binds the buffer it wrote.
	if self.direct_valid {
		found.profile_scope_args("graphics.instance_pack", "n=%d", {self.stream.count})
		self.direct_count = _backend_pack_instances(self, command_buffer, frame)
	}
	{
		found.profile_scope_args("graphics.framegraph", "frame=%d", {frame})
		if !frame_graph_execute(&self.frame_graph, command_buffer, frame, self.swapchain.extent) {
			log.errorf("[FG] Frame graph execution failed")
			return .FATAL, result
		}
	}
	command_pool_end(&self.command_pool, command_buffer)

	submit_result: vulkan.Result
	frame_value := timeline_next(&self.frame_timeline)
	{
		found.profile_scope("graphics.submit")
		wait_semaphore: vulkan.Semaphore
		wait_value: u64
		if self.direct_valid {
			wait_semaphore = vulkan.Semaphore(u64(self.stream.semaphore))
			wait_value = self.stream.value
		}
		submit_result = swapchain_submit(
			&self.swapchain,
			command_buffer,
			frame,
			image_idx,
			wait_semaphore,
			wait_value,
			self.frame_timeline.semaphore,
			frame_value,
		)
	}
	if submit_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit frame!")
		return .FATAL, result
	}
	// The frame that just read the held stream keeps it busy until it completes;
	// the caller releases it with this value on the next claim or clear.
	if self.direct_valid {
		self.direct_release_value = frame_value
	}

	present_result: vulkan.Result
	{
		found.profile_scope("graphics.present")
		present_result = swapchain_present(&self.swapchain, frame, image_idx)
	}
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
		recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to present!")
		return .FATAL, result
	}
	if sync.atomic_load(&self.window.framebuffer_resized) {recreate = true}

	if recreate {
		found.profile_mark("graphics.recreate", "frame=%d", {frame})
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
	}

	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return .OK, result
}

// _backend_init_direct creates the instance pack pipeline. It runs on the
// graphics queue inside the frame command buffer, so it needs no compute
// context of its own.
@(private)
_backend_init_direct :: proc(self: ^Backend) -> bool {
	pipeline, built := pipeline_registry_add_compute(
		&self.pipelines,
		"instance_pack",
		Compute_Config{shaders = []Shader_Spec{{job = DIRECT_SHADER}}},
	)
	if !built {return false}
	self.direct_pipeline = pipeline
	self.direct_push = push_descriptors_init(&self.gpu, DIRECT_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(
		&self.direct_push,
		pipeline_registry_get(&self.pipelines, self.direct_pipeline),
	) {
		return false
	}
	return true
}

// One readback buffer per frame in flight. The pick ID itself is a transient
// owned by the frame graph; a zero value read back means "no hit".
@(private)
_backend_create_pick_resources :: proc(self: ^Backend) -> bool {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		self.pick_readback[i] = buffer_init(&self.gpu, size_of(u32), {.TRANSFER_DST}, .HostVisible) or_return
	}
	return true
}

@(private)
_backend_destroy_pick_resources :: proc(self: ^Backend) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_destroy(&self.pick_readback[i])
		self.pick_pending[i] = false
	}
}

// Recreates the swapchain and, only if the attachment formats actually changed,
// rebuilds the pipeline. The pipeline no longer references the swapchain, so a
// plain resize reuses it as-is. The camera aspect is not touched here: the front
// keeps it in sync from the framebuffer snapshot.
@(private)
_backend_recreate_swapchain :: proc(self: ^Backend) -> bool {
	swapchain_recreate(&self.swapchain) or_return
	main := pipeline_registry_get(&self.pipelines, self.main_pipeline)
	format_changed := main.color_format != self.swapchain.image_format || main.depth_format != self.swapchain.depth_format
	if format_changed {
		pipeline_registry_destroy(&self.pipelines)
		self.pipelines = pipeline_registry_init(&self.gpu)
		color_formats := [2]vulkan.Format{self.swapchain.image_format, PICK_COLOR_FORMAT}
		self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, color_formats[:], self.swapchain.depth_format) or_return
		push_descriptors_destroy(&self.direct_push)
		_backend_init_direct(self) or_return
	}
	_backend_destroy_pick_resources(self)
	_backend_create_pick_resources(self) or_return
	return true
}

// Rebuilding a 0x0 swapchain is invalid. GLFW only updates the framebuffer size
// while processing events on the main thread, so this waits for the main-thread
// snapshot to report a valid size (the graphics thread never queries GLFW) and
// lets the next frame retry while minimized. Returns false only on a fatal
// error.
@(private)
_backend_recreate_if_possible :: proc(self: ^Backend) -> bool {
	if !window_framebuffer_valid(self.window) {
		time.sleep(16 * time.Millisecond)
		return true
	}
	return _backend_recreate_swapchain(self)
}

// Import resolver: maps the graph's external resource names to the targets and
// buffers that exist for the current frame.
@(private)
_backend_resolve_import :: proc(user: rawptr, name: string, frame: u32, out: ^Fg_Resolved) -> bool {
	self := cast(^Backend)user
	switch name {
	case "swapchain":
		out.target = self.frame_color
	case "depth":
		out.target = swapchain_depth_target(&self.swapchain, frame)^
	case "pick_readback":
		out.is_buffer = true
		out.buffer = self.pick_readback[frame].buffer
	case "camera":
		out.is_buffer = true
		out.buffer = push_descriptors_buffer(&self.push, CAMERA_SET, CAMERA_BINDING, frame)
	case:
		log.errorf("[FG] Unknown import %q", name)
		return false
	}
	return true
}

// Dispatch by pass name: the JSON owns the structure, this owns the draw calls.
@(private)
_backend_record_pass :: proc(user: rawptr, fg: ^Frame_Graph, pass: ^Fg_Pass, cmd: vulkan.CommandBuffer, frame: u32) {
	self := cast(^Backend)user
	switch pass.name {
	case "main":
		_backend_draw_main(self, cmd, frame, pass)
	case "pick_copy":
		_backend_copy_pick(self, fg, cmd, frame)
	case:
		log.errorf("[FG] No recording proc for pass %q", pass.name)
	}
}

@(private)
_backend_current_draw :: proc(self: ^Backend) -> ^gfx.Draw {
	if self.packet == nil || len(self.packet.draws) == 0 {return nil}
	return &self.packet.draws[0]
}

@(private)
_backend_draw_main :: proc(self: ^Backend, cmd: vulkan.CommandBuffer, frame: u32, pass: ^Fg_Pass) {
	pipeline := pipeline_registry_get(&self.pipelines, pass.pipeline)

	ubo := self.packet.camera
	push_descriptors_write(&self.push, CAMERA_SET, CAMERA_BINDING, frame, &ubo, size_of(gfx.Camera_Uniforms))

	valid := 0
	if self.direct_valid {
		valid = self.direct_count
	} else if draw := _backend_current_draw(self); draw != nil {
		if draw.material != pass.pipeline_name {
			log.errorf("[FG] Draw material %q does not match pass pipeline %q", draw.material, pass.pipeline_name)
		}
		n := len(draw.positions)
		if n > 0 {
			found.profile_scope_args("graphics.instances", "n=%d", {n})
			instance_buffer_update_positions(&self.instances, frame, draw.positions, draw.selected)
			valid = n
		}
	}
	found.profile_scope("graphics.push_descriptors")
	push_descriptors_flush(&self.push, cmd, pipeline.layout, frame)
	model_bind(&self.model, cmd, MESH_BINDING)
	instance_buffer_bind(&self.instances, cmd, frame, INSTANCE_BINDING)
	// Draw exactly the instances updated this frame; drawing more would reuse
	// stale data in this frame's instance buffer.
	if valid > 0 {
		found.profile_scope_args("graphics.draw_indexed", "instances=%d", {valid})
		vulkan.CmdDrawIndexed(cmd, self.model.index_count, u32(valid), 0, 0, 0)
	}
}

// _buffer_handle unwraps a neutral buffer handle into its Vulkan handle. Every
// neutral buffer was created through this backend's compute API, so the handle
// is one of our `Buffer` values.
@(private)
_buffer_handle :: proc(b: gfx.Buffer) -> vulkan.Buffer {
	if b.id == nil {return 0}
	return (cast(^Buffer)b.id).buffer
}

// _backend_verify_stream gives the stream's owner a one-shot chance to check the
// instance data the pack shader produced. The previous frame that used this slot
// has completed (the fence above), so its instance data is readable. The backend
// supplies the mapped buffer; the owner supplies the reference (the GPU physics
// package compares against its published snapshot), so no engine types leak in.
@(private)
_backend_verify_stream :: proc(self: ^Backend, frame: u32) {
	when ODIN_DEBUG {
		if !self.direct_valid || self.stream.verify == nil {return}
		count := min(self.stream.count, self.instances.capacity)
		instances := cast([^]InstanceData)self.instances.buffers[frame].mapped
		if count == 0 || instances == nil {return}
		self.stream.verify(self.stream.verify_user, frame, instances, count)
	}
}

// _backend_pack_instances builds this frame's instance data on the GPU from the
// producer's stream and returns the instance count. The frame submission waits
// on the producer's timeline, so the buffers are complete here.
@(private)
_backend_pack_instances :: proc(self: ^Backend, cmd: vulkan.CommandBuffer, frame: u32) -> int {
	view := &self.stream
	count := min(view.count, self.instances.capacity)
	if count <= 0 {return 0}

	pipeline := pipeline_registry_get(&self.pipelines, self.direct_pipeline)
	pipeline_bind_compute(pipeline, cmd)
	push := Instance_Pack_Push{count = u32(count), mode = view.mode}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Instance_Pack_Push))

	// Bodies are pool-indexed in octree mode, so their range must cover every
	// entity the live list can name: use the whole capacity for the pool-indexed
	// columns (bodies/radii/selected) and the live count for the slot-indexed
	// list.
	pool_range := vulkan.DeviceSize(view.capacity * size_of(u32))
	bodies_range := vulkan.DeviceSize(view.capacity * view.body_stride)
	live_range := vulkan.DeviceSize(count * size_of(u32))
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_BODIES_BINDING, frame, _buffer_handle(view.bodies), 0, bodies_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_RADII_BINDING, frame, _buffer_handle(view.radii), 0, pool_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_SELECTED_BINDING, frame, _buffer_handle(view.selected), 0, pool_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_LIVE_BINDING, frame, _buffer_handle(view.live), 0, live_range)
	instances := &self.instances.buffers[frame]
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_INSTANCES_BINDING, frame, instances.buffer, 0, instances.size)
	push_descriptors_flush(&self.direct_push, cmd, pipeline.layout, frame)

	groups := u32((count + DIRECT_WORKGROUP - 1) / DIRECT_WORKGROUP)
	vulkan.CmdDispatch(cmd, groups, 1, 1)

	buffer_barrier(
		cmd,
		instances.buffer,
		0,
		instances.size,
		{.COMPUTE_SHADER},
		{.VERTEX_INPUT},
		{.SHADER_STORAGE_WRITE},
		{.VERTEX_ATTRIBUTE_READ},
	)
	return count
}

// Copies the one ID pixel under the cursor. The frame graph has already put the
// pick_id target in TRANSFER_SRC; the copy rides in the frame command buffer.
// The request itself is cleared by the front once this frame returns OK.
@(private)
_backend_copy_pick :: proc(self: ^Backend, fg: ^Frame_Graph, cmd: vulkan.CommandBuffer, frame: u32) {
	if self.packet == nil || self.pick_pending[frame] {return}
	pick := self.packet.pick
	if !pick.requested {return}

	target := fg_texture(fg, "pick_id")
	if target == nil || target.image == 0 {return}
	x := u32(clamp(pick.u, 0, 1) * f32(target.extent.width - 1) + 0.5)
	y := u32(clamp(pick.v, 0, 1) * f32(target.extent.height - 1) + 0.5)

	region := vulkan.BufferImageCopy{
		bufferOffset     = 0,
		bufferRowLength   = 0,
		bufferImageHeight = 0,
		imageSubresource = vulkan.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = vulkan.Offset3D{x = i32(x), y = i32(y), z = 0},
		imageExtent = vulkan.Extent3D{width = 1, height = 1, depth = 1},
	}
	vulkan.CmdCopyImageToBuffer(cmd, target.image, .TRANSFER_SRC_OPTIMAL, fg_buffer(fg, "pick_readback"), 1, &region)
	self.pick_pending[frame] = true
	log.debugf("[PICK] copy (%d, %d) slot=%d", x, y, frame)
}

// Reads a pending result. The caller must have ensured the slot's frame fence is
// signaled (the copy is part of that frame's submission). The result is returned
// to the front, which applies it to the simulation.
@(private)
_backend_pick_resolve_slot :: proc(self: ^Backend, frame: u32, result: ^gfx.Frame_Result) {
	if !self.pick_pending[frame] {return}
	id := (cast(^u32)self.pick_readback[frame].mapped)^
	result.picked = i32(-1)
	if id != 0 {result.picked = i32(id - 1)}
	result.has_pick = true
	self.pick_pending[frame] = false
	log.debugf("[PICK] slot %d instance %d", frame, result.picked)
}

// Non-blocking: resolves any slot whose frame has already completed, so a click
// is normally applied a frame later without ever stalling.
@(private)
_backend_pick_resolve_ready :: proc(self: ^Backend, result: ^gfx.Frame_Result) {
	for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if !self.pick_pending[frame] {continue}
		if vulkan.GetFenceStatus(self.gpu.device, self.swapchain.in_flight_fences[frame]) == .SUCCESS {
			_backend_pick_resolve_slot(self, u32(frame), result)
		}
	}
}
