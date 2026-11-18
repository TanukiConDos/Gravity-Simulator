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
// init; those columns are entity-indexed and do not change per frame.
@(private)
instance_seed_backend :: proc(backend: ^vk.Backend, world: ^ecs.World) {
	if phys.body_count(world) == 0 {return}
	vk.backend_instances_seed(backend, phys.body_view(world))
}
