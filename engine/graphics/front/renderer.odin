package graphic

import gfx "engine:graphics/shared"
import vk "engine:graphics/backend"
import ecs "engine:ecs"
import found "engine:foundation"
import "core:log"

// Frame_Source_Handle names the module that supplies this frame's simulation
// data and receives pick results. It is opaque to the front: the physics side
// owns the snapshot and the pick state, exactly like the GPU stream handle.
Frame_Source_Handle :: distinct rawptr

// Frame_Source_Ops is the physics side's dispatch table.
Frame_Source_Ops :: struct {
	// instances returns this frame's instance columns in draw-slot order. The
	// slices are owned by the source and stay valid until the next call.
	// `gpu_active` tells the front whether a GPU stream producer is live; when it
	// is false the front releases any stream it holds and draws the columns.
	instances: proc(handle: Frame_Source_Handle) -> (positions: []gfx.Vec3, selected: []u8, gpu_active: bool),
	// pick receives a resolved pick index (-1 = nothing hit).
	pick:      proc(handle: Frame_Source_Handle, picked: i32),
}

// Renderer is the front-end handle: camera, input, the opaque frame-source and
// GPU-stream handles, the compute context the physics module drives, and the
// frame loop. It never imports the physics module and never calls Vulkan; the
// compute context is the only GPU resource it owns, and it borrows the backend's
// device. main owns the backend and destroys it after this handle.
Renderer :: struct {
	backend:    ^vk.Backend,
	world:      ^ecs.World,
	camera:     ^Camera,
	// Compute context attached to the backend's device on first request
	// (`renderer_compute`). Created and closed by the front; producers borrow it.
	compute:    ^vk.Compute,
	frame_handle: Frame_Source_Handle,
	frame_ops:    Frame_Source_Ops,
}

renderer_init :: proc(
	backend: ^vk.Backend,
	window: ^vk.Window,
	world: ^ecs.World,
) -> (
	result: ^Renderer,
	ok: bool,
) {
	self := new(Renderer)
	committed := false
	defer if !committed {renderer_destroy(self)}

	self.backend = backend
	self.world = world
	self.camera = ecs.world_resource(world, Camera)

	aspect := f32(16) / f32(9)
	if width, height := vk.window_framebuffer_size(window); width > 0 && height > 0 {
		aspect = f32(width) / f32(height)
	}
	self.camera^ = camera_create(aspect)
	ecs.world_resource(world, Window_Ref).input = &window.input
	_ = ecs.world_resource(world, Pick_Request)

	log.infof("========================================")
	log.infof("[RENDER] FRONT INITIALIZATION COMPLETE")
	log.infof("========================================")
	ecs.world_resource(world, Renderer_Ref).renderer = self
	committed = true
	return self, true
}

// Registers the graphics systems. Input mutates the Camera resource, and render
// runs the frame; the dependency makes render read the camera already updated
// for this frame regardless of registration order.
graphic_register_systems :: proc(s: ^ecs.Scheduler) {
	input := ecs.scheduler_add(s, "graphic.input", .RENDER, input_system)
	ecs.scheduler_add(s, "graphic.render", .RENDER, renderer_system, after = {input})
}

// RENDER-phase system: draws one frame through the renderer resource. It returns
// false only on a fatal backend error, which aborts the phase (and the app).
@(private)
renderer_system :: proc(w: ^ecs.World, delta_seconds: f32) -> bool {
	ref := ecs.world_resource(w, Renderer_Ref)
	if ref.renderer == nil {return true}
	return renderer_draw_frame(ref.renderer)
}

// renderer_set_frame_source installs (or clears, with a nil handle) the module
// that supplies the CPU instance columns and receives pick results.
renderer_set_frame_source :: proc(self: ^Renderer, handle: Frame_Source_Handle, ops: Frame_Source_Ops) {
	if self == nil {return}
	self.frame_handle = handle
	self.frame_ops = ops
}

// renderer_request_shader_reload asks the backend to rebuild its graphics
// pipelines on the next frame. Safe to call from the main thread.
renderer_request_shader_reload :: proc(self: ^Renderer) {
	if self == nil {return}
	vk.backend_request_shader_reload(self.backend)
}

// renderer_request_frame_graph_reload asks the backend to re-parse
// `frame_graph.json` on the next frame.
renderer_request_frame_graph_reload :: proc(self: ^Renderer) {
	if self == nil {return}
	vk.backend_request_frame_graph_reload(self.backend)
}

// renderer_seed_instances uploads the static per-body instance columns once.
renderer_seed_instances :: proc(self: ^Renderer, bodies: []u32, radii: []f32, selected: []u8) {
	if self == nil {return}
	vk.backend_instances_seed(self.backend, bodies, radii, selected)
}

// renderer_reseed_instances refreshes the static columns after the body list
// changed. It is called on the graphics thread before a frame and waits for the
// frame timeline before touching buffers a previous frame may still read.
renderer_reseed_instances :: proc(self: ^Renderer, bodies: []u32, radii: []f32, selected: []u8) {
	if self == nil {return}
	vk.backend_instances_reseed(self.backend, bodies, radii, selected)
}

// renderer_set_stream_producer installs (or clears) the GPU stream producer.
// The producer package passes its opaque handle and dispatch table; the front
// only forwards them to the backend.
renderer_set_stream_producer :: proc(self: ^Renderer, handle: gfx.Stream_Handle, ops: gfx.Stream_Ops) {
	if self == nil {return}
	vk.backend_set_stream_producer(self.backend, handle, ops)
}

renderer_destroy :: proc(self: ^Renderer) {
	if self == nil {return}
	// The compute context borrows the backend's device, so it is closed here,
	// before main destroys the backend. Producers must already be destroyed.
	if self.compute != nil {
		vk.compute_detach(self.compute)
		self.compute = nil
	}
	if self.world != nil {
		if ref := ecs.world_resource(self.world, Renderer_Ref); ref != nil {ref.renderer = nil}
		if window := ecs.world_resource(self.world, Window_Ref); window != nil {window.input = nil}
	}
	free(self)
	log.infof("[RENDER] Front renderer shutdown complete")
}

// renderer_draw_frame asks the frame source for this frame's data, builds the
// packet and hands it to the backend. The backend owns resize, acquire, submit
// and present; the source owns the simulation handoff.
renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	if self.backend == nil || self.world == nil {return false}

	req := ecs.world_resource(self.world, Pick_Request)
	draw := gfx.Draw{mesh = gfx.MESH_PRIMARY, material = "main"}

	if self.frame_handle != nil && self.frame_ops.instances != nil {
		positions: []gfx.Vec3
		selected: []u8
		gpu_active: bool
		{
			found.profile_scope("graphics.frame_source")
			positions, selected, gpu_active = self.frame_ops.instances(self.frame_handle)
		}
		if gpu_active {
			vk.backend_pump_stream(self.backend)
		} else {
			// No solver owns the world (or it was uninstalled): release any held
			// stream and fall back to the CPU columns.
			vk.backend_clear_stream(self.backend)
		}
		if vk.backend_instance_mode(self.backend) == .CPU && len(positions) > 0 {
			draw.positions = positions
			draw.selected = selected
		}
	}

	packet := gfx.Frame_Packet {
		camera = camera_uniforms(self.camera),
		draws  = []gfx.Draw{draw},
		pick   = gfx.Pick_Request{requested = req.requested, u = req.u, v = req.v},
	}
	status, result := vk.backend_draw(self.backend, &packet)

	if result.has_pick && self.frame_ops.pick != nil {
		self.frame_ops.pick(self.frame_handle, result.picked)
	}
	switch status {
	case .RETRY:
	// Nothing was submitted and the pick request is still pending; retry next
	// frame with the same state.
	case .FATAL:
		return false
	case .OK:
		req.requested = false
	}
	return true
}
