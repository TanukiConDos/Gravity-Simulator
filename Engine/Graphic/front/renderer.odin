package graphic

import gfx "../shared"
import vk "../backend"
import phys "../../physic"
import ecs "../../ecs"
import found "../../../foundation"
import "core:log"
import "core:sync"

// Renderer is the front-end handle: it owns the camera, the CPU instance
// columns and the pick request, and talks to the backend through the plain
// structs in `gfx`. It never calls Vulkan and owns no GPU resource; main owns
// the backend and destroys it after this handle.
Renderer :: struct {
	backend:   ^vk.Backend,
	world:     ^ecs.World,
	camera:    ^Camera,
	snapshot:  ^phys.RenderSnapshot,
	positions: [dynamic]gfx.Vec3,
	selected:  [dynamic]u8,
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
	self.snapshot = phys.physic_snapshot(world)
	instance_columns_reserve(self, phys.body_count(world))
	instance_seed_backend(backend, world)

	log.infof("========================================")
	log.infof("[RENDER] FRONT INITIALIZATION COMPLETE (%d objects)", phys.body_count(world))
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

renderer_destroy :: proc(self: ^Renderer) {
	if self == nil {return}
	if self.world != nil {
		if ref := ecs.world_resource(self.world, Renderer_Ref); ref != nil {ref.renderer = nil}
		if window := ecs.world_resource(self.world, Window_Ref); window != nil {window.input = nil}
	}
	delete(self.positions)
	delete(self.selected)
	free(self)
	log.infof("[RENDER] Front renderer shutdown complete")
}

// renderer_draw_frame builds this frame's packet and hands it to the backend.
// The backend owns resize, acquire, submit and present; the front fills the
// camera, the instance columns and the pick request, then applies a resolved
// pick to the simulation.
renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	if self.backend == nil || self.world == nil {return false}

	req := ecs.world_resource(self.world, Pick_Request)
	draw := gfx.Draw{mesh = gfx.MESH_PRIMARY, material = "main"}

	if vk.backend_instance_mode(self.backend) == .CPU && len(self.positions) > 0 {
		n: int
		{
			found.profile_scope_args("graphics.snapshot_read", "max=%d", {len(self.positions)})
			n = phys.physic_snapshot_read(
				self.snapshot,
				raw_data(self.positions),
				raw_data(self.selected),
				len(self.positions),
			)
		}
		if n > 0 {
			draw.positions = self.positions[:n]
			draw.selected = self.selected[:n]
		}
	}

	packet := gfx.Frame_Packet {
		camera = camera_uniforms(self.camera),
		draws  = []gfx.Draw{draw},
		pick   = gfx.Pick_Request{requested = req.requested, u = req.u, v = req.v},
	}
	status, result := vk.backend_draw(self.backend, &packet)

	if result.has_pick {
		sel := phys.selection_state(self.world)
		sync.atomic_store(&sel.picked, result.picked)
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
