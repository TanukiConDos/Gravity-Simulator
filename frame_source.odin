package main

import graphic "./Engine/Graphic/front"
import gfx "./Engine/Graphic/shared"
import physic "./Engine/physic"
import ecs "./Engine/ecs"
import "core:sync"

// Frame_Source is main's adapter between the simulation and the graphics front.
// `main` orchestrates the modules, so it owns the CPU instance columns, seeds the
// backend's static columns once and receives pick results; the front sees only an
// opaque handle and never imports physics.
@(private)
Frame_Source :: struct {
	renderer:  ^graphic.Renderer,
	world:     ^ecs.World,
	snapshot:  ^physic.RenderSnapshot,
	positions: [dynamic]gfx.Vec3,
	selected:  [dynamic]u8,
}

@(private)
frame_source_init :: proc(self: ^Frame_Source, renderer: ^graphic.Renderer, world: ^ecs.World) {
	self.renderer = renderer
	self.world = world
	self.snapshot = physic.physic_snapshot(world)

	count := physic.body_count(world)
	if count > 0 {
		self.positions = make([dynamic]gfx.Vec3, count)
		self.selected = make([dynamic]u8, count)

		view := physic.body_view(world)
		radii := make([]f32, count, context.temp_allocator)
		selected := make([]u8, count, context.temp_allocator)
		for entity in view.bodies {
			radii[entity] = f32(view.radius[entity])
			selected[entity] = bool(view.selected[entity]) ? 1 : 0
		}
		graphic.renderer_seed_instances(renderer, view.bodies, radii, selected)
	}

	graphic.renderer_set_frame_source(
		renderer,
		graphic.Frame_Source_Handle(rawptr(self)),
		graphic.Frame_Source_Ops{instances = _frame_source_instances, pick = _frame_source_pick},
	)
}

@(private)
frame_source_destroy :: proc(self: ^Frame_Source) {
	if self == nil {return}
	if self.renderer != nil {
		graphic.renderer_set_frame_source(self.renderer, nil, {})
	}
	delete(self.positions)
	delete(self.selected)
}

// _frame_source_instances runs on the graphics thread. `physic_snapshot_read` is
// the lock-free triple-buffer handoff; the slices stay valid until the next call.
// `gpu_active` is the producer liveness signal the front uses to pump/clear the
// stream.
@(private)
_frame_source_instances :: proc(
	handle: graphic.Frame_Source_Handle,
) -> (
	positions: []gfx.Vec3,
	selected: []u8,
	gpu_active: bool,
) {
	self := cast(^Frame_Source)rawptr(handle)
	n := physic.physic_snapshot_read(
		self.snapshot,
		raw_data(self.positions),
		raw_data(self.selected),
		len(self.positions),
	)
	return self.positions[:n], self.selected[:n], physic.physic_gravity_backend_active(self.world)
}

// _frame_source_pick hands a resolved pick to the physics thread through the
// atomic selection state.
@(private)
_frame_source_pick :: proc(handle: graphic.Frame_Source_Handle, picked: i32) {
	self := cast(^Frame_Source)rawptr(handle)
	sync.atomic_store(&physic.selection_state(self.world).picked, picked)
}
