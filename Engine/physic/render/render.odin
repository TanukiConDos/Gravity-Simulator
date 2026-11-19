// Package physic_render is the physics side of the graphics handoff. It owns the
// CPU instance columns and the pick handoff, and implements the front's
// Frame_Source. The dependency goes physic -> front; the front knows nothing
// about physics.
package physic_render

import graphic "../../Graphic/front"
import gfx "../../Graphic/shared"
import phys "../../physic"
import ecs "../../ecs"
import "core:sync"

Source :: struct {
	renderer:  ^graphic.Renderer,
	world:     ^ecs.World,
	snapshot:  ^phys.RenderSnapshot,
	positions: [dynamic]gfx.Vec3,
	selected:  [dynamic]u8,
}

// init seeds the backend's static instance columns and registers this package as
// the renderer's frame source. Call it after `graphic.renderer_init` and after
// the world's bodies exist, before the simulation threads start.
init :: proc(renderer: ^graphic.Renderer, world: ^ecs.World) -> (result: ^Source, ok: bool) {
	self := new(Source)
	self.renderer = renderer
	self.world = world
	self.snapshot = phys.physic_snapshot(world)

	count := phys.body_count(world)
	if count > 0 {
		self.positions = make([dynamic]gfx.Vec3, count)
		self.selected = make([dynamic]u8, count)

		view := phys.body_view(world)
		radii := make([]f32, count, context.temp_allocator)
		selected := make([]u8, count, context.temp_allocator)
		for entity in view.bodies {
			radii[entity] = f32(view.radius[entity])
			selected[entity] = bool(view.selected[entity]) ? 1 : 0
		}
		graphic.renderer_seed_instances(renderer, view.bodies, radii, selected)
	}

	graphic.renderer_set_frame_source(renderer, handle(self), ops())
	return self, true
}

destroy :: proc(self: ^Source) {
	if self == nil {return}
	if self.renderer != nil {
		graphic.renderer_set_frame_source(self.renderer, nil, {})
	}
	delete(self.positions)
	delete(self.selected)
	free(self)
}

handle :: proc(self: ^Source) -> graphic.Frame_Source_Handle {
	return graphic.Frame_Source_Handle(rawptr(self))
}

ops :: proc() -> graphic.Frame_Source_Ops {
	return graphic.Frame_Source_Ops{instances = _instances, pick = _pick}
}

// _instances claims the latest published CPU snapshot. It runs on the graphics
// thread; `physic_snapshot_read` is the lock-free triple-buffer handoff, and the
// slices remain valid until the next call.
@(private)
_instances :: proc(handle: graphic.Frame_Source_Handle) -> (positions: []gfx.Vec3, selected: []u8, gpu_active: bool) {
	self := cast(^Source)rawptr(handle)
	n := phys.physic_snapshot_read(
		self.snapshot,
		raw_data(self.positions),
		raw_data(self.selected),
		len(self.positions),
	)
	return self.positions[:n], self.selected[:n], phys.physic_gravity_backend_active(self.world)
}

// _pick hands a resolved pick to the physics thread through the atomic selection
// state.
@(private)
_pick :: proc(handle: graphic.Frame_Source_Handle, picked: i32) {
	self := cast(^Source)rawptr(handle)
	sync.atomic_store(&phys.selection_state(self.world).picked, picked)
}
