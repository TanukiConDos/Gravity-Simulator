package graphic

import gfx "../shared"
import vk "../backend"
import phys "../../physic"
import ecs "../../ecs"

// The front owns the per-frame instance columns and the batching decision; the
// backend owns the vertex layout, the GPU buffers and the upload. `positions`
// and `selected` are packed in draw-slot order by `physic_snapshot_read`, which
// is the order the instance vertex stream expects.

@(private)
instance_columns_reserve :: proc(self: ^Renderer, count: int) {
	if count <= 0 {return}
	self.positions = make([dynamic]gfx.Vec3, count)
	self.selected = make([dynamic]u8, count)
}

// One-time static seed (radius + initial selection) handed to the backend at
// init. The body view is entity-indexed, so this converts it into the plain
// columns the backend takes; the slot -> entity mapping stays the identity of
// `view.bodies`.
@(private)
instance_seed_backend :: proc(backend: ^vk.Backend, world: ^ecs.World) {
	view := phys.body_view(world)
	count := len(view.bodies)
	if count == 0 {return}
	radii := make([]f32, count, context.temp_allocator)
	selected := make([]u8, count, context.temp_allocator)
	for entity in view.bodies {
		radii[entity] = f32(view.radius[entity])
		selected[entity] = bool(view.selected[entity]) ? 1 : 0
	}
	vk.backend_instances_seed(backend, view.bodies, radii, selected)
}
