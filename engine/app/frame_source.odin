package app

import graphic "engine:graphics/front"
import gfx "engine:graphics/shared"
import physics "engine:physics"
import ecs "engine:ecs"
import "core:sync"

// Frame_Source is the runtime's adapter between the simulation and the graphics
// front. The runtime owns the CPU instance columns, seeds the backend's static
// columns once and receives pick results; the front sees only an opaque handle
// and never imports physics.
//
// The static columns (entity order, radius, selection) live behind a mutex
// because a hot-reloaded gameplay layer can spawn bodies on the physics thread
// while the graphics thread is preparing a frame. Only the physics thread writes
// them, and only on a spawn/despawn request; the graphics thread copies them into
// the backend before `backend_draw`.
@(private)
Frame_Source :: struct {
	renderer:  ^graphic.Renderer,
	world:     ^ecs.World,
	snapshot:  ^physics.RenderSnapshot,
	positions: [dynamic]gfx.Vec3,
	selected:  [dynamic]u8,

	static:        Static_Columns,
	static_mutex:  sync.Mutex,
	reseed_pending: u32,
}

// `bodies` is slot -> entity (dense draw order). `radii` and `selected` are
// entity-indexed, matching `backend_instances_seed`; their length covers the
// world's entity budget so a reused index always has a slot.
@(private)
Static_Columns :: struct {
	bodies:   [dynamic]u32,
	radii:    [dynamic]f32,
	selected: [dynamic]u8,
	count:    int,
}

@(private)
frame_source_init :: proc(self: ^Frame_Source, renderer: ^graphic.Renderer, world: ^ecs.World) {
	self.renderer = renderer
	self.world = world
	self.snapshot = physics.physics_snapshot(world)

	capacity := max(world.capacity, physics.body_count(world))
	self.static.bodies = make([dynamic]u32, 0, capacity)
	self.static.radii = make([dynamic]f32, capacity)
	self.static.selected = make([dynamic]u8, capacity)
	_frame_source_refresh_static(self)

	if self.static.count > 0 {
		self.positions = make([dynamic]gfx.Vec3, self.static.count)
		self.selected = make([dynamic]u8, self.static.count)
		graphic.renderer_seed_instances(
			renderer,
			self.static.bodies[:self.static.count],
			self.static.radii[:],
			self.static.selected[:],
		)
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
	delete(self.static.bodies)
	delete(self.static.radii)
	delete(self.static.selected)
}

// frame_source_reseed_callback adapts the typed request to the engine/hot Host
// callback, which keeps that package independent of `package main`.
@(private)
frame_source_reseed_callback :: proc(user: rawptr) {
	frame_source_request_reseed(cast(^Frame_Source)user)
}

// frame_source_request_reseed must be called on the thread that owns the world
// (the physics thread after it spawns/despawns, or the main thread before the
// threads start). It refreshes the static columns and marks them for upload.
frame_source_request_reseed :: proc(self: ^Frame_Source) {
	if self == nil {return}
	sync.lock(&self.static_mutex)
	_frame_source_refresh_static(self)
	sync.unlock(&self.static_mutex)
	sync.atomic_store(&self.reseed_pending, u32(1))
}

@(private)
_frame_source_refresh_static :: proc(self: ^Frame_Source) {
	view := physics.body_view(self.world)
	count := len(view.bodies)
	// `bodies` is draw-order; the other columns are entity-indexed. Reserve for
	// the world budget so a reused entity index always has a slot.
	max_entity := int(self.world.capacity)
	for entity in view.bodies {
		if int(entity) + 1 > max_entity {max_entity = int(entity) + 1}
	}
	resize(&self.static.bodies, count)
	if max_entity > len(self.static.radii) {resize(&self.static.radii, max_entity)}
	if max_entity > len(self.static.selected) {resize(&self.static.selected, max_entity)}
	for entity, slot in view.bodies {
		self.static.bodies[slot] = entity
		self.static.radii[entity] = f32(view.radius[entity])
		self.static.selected[entity] = bool(view.selected[entity]) ? 1 : 0
	}
	self.static.count = count
}

// _frame_source_instances runs on the graphics thread. `physics_snapshot_read` is
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

	if sync.atomic_load(&self.reseed_pending) != 0 {
		sync.atomic_store(&self.reseed_pending, u32(0))
		sync.lock(&self.static_mutex)
		count := self.static.count
		if count > len(self.positions) {
			resize(&self.positions, count)
			resize(&self.selected, count)
		}
		graphic.renderer_reseed_instances(
			self.renderer,
			self.static.bodies[:count],
			self.static.radii[:],
			self.static.selected[:],
		)
		sync.unlock(&self.static_mutex)
	}

	n := physics.physics_snapshot_read(
		self.snapshot,
		raw_data(self.positions),
		raw_data(self.selected),
		len(self.positions),
	)
	return self.positions[:n], self.selected[:n], physics.physics_gravity_backend_active(self.world)
}

// _frame_source_pick hands a resolved pick to the physics thread through the
// atomic selection state.
@(private)
_frame_source_pick :: proc(handle: graphic.Frame_Source_Handle, picked: i32) {
	self := cast(^Frame_Source)rawptr(handle)
	sync.atomic_store(&physics.selection_state(self.world).picked, picked)
}
