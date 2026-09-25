package physic

import found "../../foundation"
import ecs "../ecs"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:time"

ADAPTIVE_EMA_ALPHA :: 0.1
ADAPTIVE_WARMUP :: 20
ADAPTIVE_COOLDOWN :: 5
ADAPTIVE_CONFIRM :: 2
ADAPTIVE_DEADBAND :: 0.15
ADAPTIVE_THETA_STEP :: 0.03
ADAPTIVE_HEADROOM :: 0.85
ADAPTIVE_STALE_FACTOR :: 0.5
ADAPTIVE_MIN_REBUILD_UPDATES :: 2

// The published render view is a triple buffer: the physics thread writes into a
// free buffer and atomically publishes it, the graphics thread claims the latest
// published buffer and reads it. Latest wins, the writer never blocks and the
// reader always sees a complete version. Only the two side threads touch it (one
// writer, one reader), so the state machine is per buffer.
SNAPSHOT_BUFFERS :: 3

Snapshot_State :: enum(u32) {
	FREE,
	WRITING,
	READING,
	PUBLISHED,
}

Snapshot_Buffer :: struct {
	data:     []Vec3,
	selected: []u8,
	count:    int,
	state:    u32, // atomic Snapshot_State
}

RenderSnapshot :: struct {
	buffers:   [SNAPSHOT_BUFFERS]Snapshot_Buffer,
	published: i32, // atomic buffer index, -1 when nothing has been published
	capacity:  int,
}

// Set by the graphics thread after a pick readback and consumed by the physics
// thread, which is the only side allowed to touch the pools. A value of
// SELECTION_NONE means "no pending request".
SELECTION_NONE :: i32(-1)

Selection_State :: struct {
	picked: i32,
}

// Solver/adaptive state lives as a world resource; the physics systems fetch it
// at the start of a tick and keep the pointer for their duration.
Physic_State :: struct {
	algorithm:           found.Algorithm,
	theta:               f32,
	rebuild_interval:    f32,
	max_depth:           int,
	min_half:            f32,
	tree:                ^OctTree,
	tree_accumulator:    f32,
	tree_body_count:     int,
	tree_revision:       u64,
	collision_contacts:  [dynamic]Contact,
	collision_mutex:     sync.Mutex,
	auto_adjust:         bool,
	target_cost_ms:      f32,
	theta_min:           f32,
	theta_max:           f32,
	ema_cost_ms:         f32,
	max_disp_sq:         f32,
	build_positions:     [dynamic]Vec3,
	updates_since_build: int,
	rebuild_count:       int,
	warmup_left:         int,
	cooldown_left:       int,
	above_count:         int,
	below_count:         int,
	tick_start:          time.Tick,
}

@(private)
_state_destroy :: proc(ptr: rawptr) {
	s := cast(^Physic_State)ptr
	if s.tree != nil {octtree_destroy(s.tree)}
	delete(s.collision_contacts)
	delete(s.build_positions)
	free(ptr)
}

@(private)
_snapshot_destroy :: proc(ptr: rawptr) {
	s := cast(^RenderSnapshot)ptr
	for &b in s.buffers {
		delete(b.data)
		delete(b.selected)
	}
	free(ptr)
}

// Sizes every buffer for `capacity` bodies. Owner-thread only (no reader is
// running during setup); growing while a reader holds a buffer would free the
// memory it is reading.
snapshot_reserve :: proc(s: ^RenderSnapshot, capacity: int) {
	if capacity <= s.capacity {return}
	for &b in s.buffers {
		delete(b.data)
		delete(b.selected)
		b.data = make([]Vec3, capacity)
		b.selected = make([]u8, capacity)
		b.count = 0
		sync.atomic_store(&b.state, u32(Snapshot_State.FREE))
	}
	sync.atomic_store(&s.published, i32(-1))
	s.capacity = capacity
}

physic_state :: proc(w: ^ecs.World) -> ^Physic_State {
	return ecs.world_resource(w, Physic_State, _state_destroy)
}

physic_snapshot :: proc(w: ^ecs.World) -> ^RenderSnapshot {
	return ecs.world_resource(w, RenderSnapshot, _snapshot_destroy)
}

selection_state :: proc(w: ^ecs.World) -> ^Selection_State {
	return ecs.world_resource(w, Selection_State)
}

physic_init :: proc(w: ^ecs.World, config: found.Config) -> ^Physic_State {
	// Create every pool and resource up front so the physics and graphics
	// threads only ever read the registries concurrently.
	snap := ecs.world_resource(w, RenderSnapshot, _snapshot_destroy)
	snapshot_reserve(snap, max(w.capacity, body_count(w)))
	sel := ecs.world_resource(w, Selection_State)
	sel.picked = SELECTION_NONE
	s := ecs.world_resource(w, Physic_State, _state_destroy)
	s.algorithm = config.algorithm
	s.theta = config.theta
	s.rebuild_interval = config.tree_rebuild_interval
	s.max_depth =
		config.max_depth > 0 ? min(config.max_depth, MAX_DEPTH_CAP) : DEFAULT_MAX_DEPTH
	s.min_half =
		config.min_half_size > 0 ? config.min_half_size : DEFAULT_MIN_HALF_SIZE
	s.auto_adjust = config.auto_adjust
	s.target_cost_ms = ADAPTIVE_HEADROOM * (1000.0 / max(config.target_tickrate, 1.0))
	s.theta_min = config.theta_min
	s.theta_max = config.theta_max
	s.ema_cost_ms = ADAPTIVE_HEADROOM * (1000.0 / max(config.target_tickrate, 1.0))
	s.warmup_left = ADAPTIVE_WARMUP

	if s.auto_adjust {
		s.theta = clamp(s.theta, s.theta_min, s.theta_max)
	}
	_ = ecs.world_pool(w, Body)
	_ = ecs.world_pool(w, Position)
	_ = ecs.world_pool(w, Velocity)
	_ = ecs.world_pool(w, Acceleration)
	_ = ecs.world_pool(w, Mass)
	_ = ecs.world_pool(w, Radius)
	_ = ecs.world_pool(w, Selected)
	return s
}

// Registers the physics systems as the PHYSICS phase. Dependencies are declared
// with handles rather than implied by registration order; `integrate` and
// `select` touch disjoint columns and may share a wave.
physic_register_systems :: proc(s: ^ecs.Scheduler) {
	begin := ecs.scheduler_add(s, "physic.begin", .PHYSICS, physic_system_begin)
	gravity := ecs.scheduler_add(
		s,
		"physic.gravity",
		.PHYSICS,
		physic_system_gravity,
		after = {begin},
	)
	collision := ecs.scheduler_add(
		s,
		"physic.collision",
		.PHYSICS,
		physic_system_collision,
		after = {gravity},
	)
	integrate := ecs.scheduler_add(
		s,
		"physic.integrate",
		.PHYSICS,
		physic_system_integrate,
		after = {collision},
		access = ecs.System_Access {
			reads = {typeid_of(Velocity), typeid_of(Physic_State)},
			writes = {typeid_of(Position), typeid_of(Physic_State)},
		},
		affinity = .ANY,
	)
	select := ecs.scheduler_add(
		s,
		"physic.select",
		.PHYSICS,
		physic_system_select,
		after = {collision},
		access = ecs.System_Access {
			reads = {typeid_of(Selection_State), typeid_of(Body)},
			writes = {typeid_of(Selected)},
		},
		affinity = .ANY,
	)
	publish := ecs.scheduler_add(
		s,
		"physic.publish",
		.PHYSICS,
		physic_system_publish,
		after = {integrate, select},
	)
	ecs.scheduler_add(s, "physic.adapt", .PHYSICS, physic_system_adapt, after = {publish})
}

physic_system_begin :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return true}
	state.tick_start = time.tick_now()

	acc := ecs.world_pool(w, Acceleration).data
	for idx in bodies {acc[idx] = Acceleration(Vec3{0, 0, 0})}

	if state.algorithm == .OCTREE {
		found.profile_scope("tree.ensure")
		_ensure_tree(state, w, delta_time)
	}
	return true
}

physic_system_gravity :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return true}
	seconds := f64(delta_time)

	switch state.algorithm {
	case .BRUTE_FORCE:
		found.profile_scope_args("brute.force", "n=%d", {len(bodies)})
		_brute_force_solve(w, bodies, seconds)
	case .OCTREE:
		if state.tree != nil {
			state.tree.theta = state.theta
			// The gravity traversal doubles as the collision broad phase:
			// positions do not change between the two phases, so the contacts
			// it collects are exactly what a separate pass would have found.
			// The collision sphere is inflated by the tree's build-time max
			// radius, so the query never hides a contact.
			clear(&state.collision_contacts)
			_octree_solve(state, bodies, seconds)
		}
	}
	return true
}

physic_system_collision :: proc(w: ^ecs.World, _: f32) -> bool {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) < 2 {return true}

	switch state.algorithm {
	case .BRUTE_FORCE:
		found.profile_scope_args("brute.collision", "n=%d", {len(bodies)})
		_brute_force_collision(w, bodies)
	case .OCTREE:
		if state.tree != nil {_collision_resolve(state, w)}
	}
	return true
}

physic_system_integrate :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return true}

	pos := ecs.world_pool(w, Position).data
	vel := ecs.world_pool(w, Velocity).data
	for idx in bodies {
		p := Vec3(pos[idx]) + Vec3(vel[idx]) * delta_time
		pos[idx] = Position(p)
		if state.auto_adjust && int(idx) < len(state.build_positions) {
			drift := p - state.build_positions[idx]
			disp_sq := drift.x * drift.x + drift.y * drift.y + drift.z * drift.z
			if disp_sq > state.max_disp_sq {state.max_disp_sq = disp_sq}
		}
	}
	return true
}

// Applies a pick result handed over by the graphics thread. Runs on the physics
// thread, which owns the Selected pool; an out-of-range index is treated as a
// miss and simply clears the selection.
physic_system_select :: proc(w: ^ecs.World, _: f32) -> bool {
	sel := selection_state(w)
	picked := sync.atomic_load(&sel.picked)
	if picked == SELECTION_NONE {return true}
	sync.atomic_store(&sel.picked, SELECTION_NONE)

	found.profile_scope_args("physic.select", "picked=%d", {picked})
	view := body_view(w)
	for idx in view.bodies {view.selected[idx] = Selected(false)}
	if picked >= 0 && int(picked) < len(view.bodies) {
		view.selected[view.bodies[int(picked)]] = Selected(true)
	}
	return true
}

physic_system_publish :: proc(w: ^ecs.World, _: f32) -> bool {
	found.profile_scope_args("snapshot.publish", "n=%d", {len(ecs.world_pool(w, Body).dense)})
	physic_snapshot_publish(w)
	return true
}

physic_system_adapt :: proc(w: ^ecs.World, _: f32) -> bool {
	state := physic_state(w)
	if len(ecs.world_pool(w, Body).dense) == 0 {return true}
	cost_ms := f32(
		time.duration_milliseconds(time.tick_diff(state.tick_start, time.tick_now())),
	)
	found.profile_scope_args(
		"physic.adapt",
		"cost=%.2fms ema=%.2fms theta=%.2f",
		{cost_ms, state.ema_cost_ms, state.theta},
	)
	_adaptive_controller(state, cost_ms)
	return true
}

@(private)
_ensure_tree :: proc(state: ^Physic_State, w: ^ecs.World, delta_time: f32) -> ^OctTree {
	view := body_view(w)
	bodies := view.bodies
	stale :=
		state.tree == nil ||
		state.tree_body_count != len(bodies) ||
		state.tree_revision != w.revision

	if !stale {
		if state.auto_adjust && state.tree != nil {
			state.tree_accumulator += delta_time
			if state.tree_accumulator >= state.rebuild_interval ||
			   adaptive_tree_stale(
				   state.max_disp_sq,
				   state.tree.typical_half,
				   state.updates_since_build,
			   ) {
				stale = true
			}
		} else if state.rebuild_interval > 0 {
			state.tree_accumulator += delta_time
			if state.tree_accumulator >= state.rebuild_interval {
				stale = true
			}
		}
	}

	if stale || (!state.auto_adjust && state.rebuild_interval <= 0) {
		found.profile_scope("octree.build")
		if state.tree != nil {
			octtree_rebuild_ex(state.tree, view, state.theta, state.max_depth, state.min_half)
		} else {
			state.tree = octtree_create_ex(view, state.theta, state.max_depth, state.min_half)
		}
		state.tree_body_count = len(bodies)
		state.tree_revision = w.revision
		state.tree_accumulator = 0
		state.updates_since_build = 0
		state.rebuild_count += 1
		if state.auto_adjust {
			if cap(state.build_positions) < len(view.position) {
				resize(&state.build_positions, len(view.position))
			}
			for idx in bodies {
				if int(idx) < len(state.build_positions) {
					state.build_positions[idx] = Vec3(view.position[idx])
				}
			}
			state.max_disp_sq = 0
		}
		found.profile_mark(
			"octree.built",
			"n=%d nodes=%d med_depth=%d max_depth=%d typical_half=%.4g rebuilds=%d",
			{
				len(bodies),
				state.tree.node_count,
				state.tree.median_leaf_depth,
				state.tree.max_leaf_depth,
				state.tree.typical_half,
				state.rebuild_count,
			},
		)
	}
	state.updates_since_build += 1
	if state.tree != nil {state.tree.view = view}
	return state.tree
}

adaptive_tree_stale :: proc(max_disp_sq, leaf_half: f32, updates_since_build: int) -> bool {
	if updates_since_build < ADAPTIVE_MIN_REBUILD_UPDATES {return false}
	threshold := ADAPTIVE_STALE_FACTOR * leaf_half
	return max_disp_sq > threshold * threshold
}

_adaptive_controller :: proc(state: ^Physic_State, cost_ms: f32) {
	if !state.auto_adjust {return}
	if state.algorithm != .OCTREE {return}

	if state.warmup_left > 0 {
		state.warmup_left -= 1
		return
	}

	state.ema_cost_ms += (cost_ms - state.ema_cost_ms) * ADAPTIVE_EMA_ALPHA

	if state.cooldown_left > 0 {
		state.cooldown_left -= 1
		return
	}

	lo := state.target_cost_ms * (1.0 - ADAPTIVE_DEADBAND)
	hi := state.target_cost_ms * (1.0 + ADAPTIVE_DEADBAND)
	in_band := state.ema_cost_ms >= lo && state.ema_cost_ms <= hi
	if in_band {
		state.above_count = 0
		state.below_count = 0
		return
	}
	if state.ema_cost_ms > hi {
		state.above_count += 1
		state.below_count = 0
	} else {
		state.below_count += 1
		state.above_count = 0
	}
	if state.above_count < ADAPTIVE_CONFIRM && state.below_count < ADAPTIVE_CONFIRM {return}

	new_theta, adapted := adaptive_decide(
		state.ema_cost_ms,
		state.target_cost_ms,
		state.theta,
		state.theta_min,
		state.theta_max,
	)
	if !adapted {return}

	old_theta := state.theta
	state.theta = new_theta
	state.cooldown_left = ADAPTIVE_COOLDOWN
	found.profile_mark("adaptive.theta", "from=%.2f to=%.2f", {old_theta, new_theta})
	log.infof(
		"[PHYSIC] adaptive: ema=%.2fms target=%.2fms theta=%.2f rebuilds=%d",
		state.ema_cost_ms,
		state.target_cost_ms,
		state.theta,
		state.rebuild_count,
	)
}

adaptive_decide :: proc(
	ema_cost, target_cost, theta, theta_min, theta_max: f32,
) -> (
	new_theta: f32,
	adapted: bool,
) {
	new_theta = theta
	if target_cost <= 0 {return}

	lo := target_cost * (1.0 - ADAPTIVE_DEADBAND)
	hi := target_cost * (1.0 + ADAPTIVE_DEADBAND)
	if ema_cost >= lo && ema_cost <= hi {return}

	if ema_cost > hi {
		if theta < theta_max {
			new_theta = min(theta + ADAPTIVE_THETA_STEP, theta_max)
			adapted = true
		}
	} else {
		if theta > theta_min {
			new_theta = max(theta - ADAPTIVE_THETA_STEP, theta_min)
			adapted = true
		}
	}
	return
}

// Claims a free buffer (FREE -> WRITING) so the writer has somewhere to build the
// next version. Returns -1 when the reader still holds every other buffer.
@(private)
_snapshot_acquire_write :: proc(s: ^RenderSnapshot) -> int {
	for i in 0 ..< SNAPSHOT_BUFFERS {
		expected := u32(Snapshot_State.FREE)
		_, ok := sync.atomic_compare_exchange_strong(
			&s.buffers[i].state,
			expected,
			u32(Snapshot_State.WRITING),
		)
		if ok {return i}
	}
	return -1
}

// Copies the pool state into the next buffer and publishes it. Owner thread only.
physic_snapshot_publish :: proc(w: ^ecs.World) {
	snapshot := physic_snapshot(w)
	view := body_view(w)
	count := len(view.bodies)
	if count > snapshot.capacity {
		log.errorf(
			"[PHYSIC] snapshot capacity %d is smaller than the body count %d",
			snapshot.capacity,
			count,
		)
		return
	}

	i := _snapshot_acquire_write(snapshot)
	if i < 0 {
		// The reader is holding every buffer; skip this version rather than
		// block the simulation. Rendering keeps the last complete frame.
		return
	}
	buf := &snapshot.buffers[i]
	buf.count = count
	for j in 0 ..< count {
		entity := view.bodies[j]
		buf.data[j] = Vec3(view.position[entity])
		buf.selected[j] = bool(view.selected[entity]) ? 1 : 0
	}
	sync.atomic_store(&buf.state, u32(Snapshot_State.PUBLISHED))
	old := sync.atomic_exchange(&snapshot.published, i32(i))
	if old >= 0 && int(old) != i {
		// Release the previous version unless the reader has claimed it.
		expected := u32(Snapshot_State.PUBLISHED)
		sync.atomic_compare_exchange_strong(
			&snapshot.buffers[old].state,
			expected,
			u32(Snapshot_State.FREE),
		)
	}
}

// Claims the latest published buffer, copies it and releases it. Reader thread
// only. Returns the number of bodies copied.
physic_snapshot_read :: proc(
	snapshot: ^RenderSnapshot,
	dest: rawptr,
	dest_selected: rawptr,
	max_count: int,
) -> int {
	for _ in 0 ..< 8 {
		p := sync.atomic_load(&snapshot.published)
		if p < 0 {return 0}
		idx := int(p)
		buf := &snapshot.buffers[idx]
		expected := u32(Snapshot_State.PUBLISHED)
		_, ok := sync.atomic_compare_exchange_strong(
			&buf.state,
			expected,
			u32(Snapshot_State.READING),
		)
		if !ok {continue}
		n := min(max_count, buf.count)
		if n > 0 && dest != nil {
			mem.copy(dest, raw_data(buf.data), n * size_of(Vec3))
		}
		if n > 0 && dest_selected != nil {
			mem.copy(dest_selected, raw_data(buf.selected), n)
		}
		sync.atomic_store(&buf.state, u32(Snapshot_State.FREE))
		return n
	}
	return 0
}

_brute_force_solve :: proc(w: ^ecs.World, bodies: []u32, seconds: f64) {
	pos := ecs.world_pool(w, Position).data
	vel := ecs.world_pool(w, Velocity).data
	acc := ecs.world_pool(w, Acceleration).data
	mass := ecs.world_pool(w, Mass).data
	n := len(bodies)
	for ii in 0 ..< n {
		i := bodies[ii]
		acc_i := Vec3(acc[i])
		mass_i := f64(mass[i])
		for jj in ii + 1 ..< n {
			j := bodies[jj]
			dir := Vec3(pos[j]) - Vec3(pos[i])
			dist_sq := f64(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
			if dist_sq < 1e-6 {dist_sq = 1e-6}
			dir_norm := dir / f32(math.sqrt_f64(dist_sq))

			g_over_dist_sq := f32(GRAVITY_CONSTANT / dist_sq)
			acc_i += dir_norm * (g_over_dist_sq * f32(mass[j]))
			acc[j] = Acceleration(Vec3(acc[j]) - dir_norm * (g_over_dist_sq * f32(mass_i)))
		}
		acc[i] = Acceleration(acc_i)
		vel[i] = Velocity(Vec3(vel[i]) + acc_i * f32(seconds))
	}
}

_brute_force_collision :: proc(w: ^ecs.World, bodies: []u32) {
	pos := ecs.world_pool(w, Position).data
	radius := ecs.world_pool(w, Radius).data
	mass := ecs.world_pool(w, Mass).data
	for ii in 0 ..< len(bodies) {
		a := bodies[ii]
		for jj in ii + 1 ..< len(bodies) {
			b := bodies[jj]
			dir := Vec3(pos[b]) - Vec3(pos[a])
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			radius_sum := f32(radius[a]) + f32(radius[b])
			if dist_sq >= radius_sum * radius_sum || dist_sq <= 0.000001 {continue}
			dist := math.sqrt_f32(dist_sq)
			normal := dir / dist
			overlap := radius_sum - dist
			total_mass := f32(f64(mass[a]) + f64(mass[b]))
			pos[a] = Position(Vec3(pos[a]) - normal * (overlap * f32(mass[b]) / total_mass))
			pos[b] = Position(Vec3(pos[b]) + normal * (overlap * f32(mass[a]) / total_mass))
		}
	}
}

_octree_solve :: proc(state: ^Physic_State, bodies: []u32, seconds: f64) {
	tree := state.tree
	if tree == nil {return}
	found.profile_scope_args(
		"octree.solve",
		"n=%d theta=%.2f max_r=%.4g workers=%d",
		{len(bodies), tree.theta, tree.max_radius, found.parallel_worker_count()},
	)
	data := _OctreeSolveData {
		tree     = tree,
		indices  = bodies,
		dt       = f32(seconds),
		contacts = &state.collision_contacts,
		mutex    = &state.collision_mutex,
	}
	found.parallel_for(_octree_solve_worker, &data, len(bodies))
	found.profile_mark("octree.solved", "pairs=%d", {len(state.collision_contacts)})
}

_OctreeSolveData :: struct {
	tree:     ^OctTree,
	indices:  []u32,
	dt:       f32,
	contacts: ^[dynamic]Contact,
	mutex:    ^sync.Mutex,
}

_octree_solve_worker :: proc(index: int, data: rawptr) {
	ctx := cast(^_OctreeSolveData)data
	octtree_calc_force_and_collect(
		ctx.tree,
		ctx.indices[index],
		ctx.dt,
		ctx.contacts,
		ctx.mutex,
	)
}

// Overlapping pair collected during the gravity traversal.
Contact :: struct {
	a: u32,
	b: u32,
}

@(private)
_contact_less :: proc(x, y: Contact) -> bool {
	if x.a != y.a {return x.a < y.a}
	return x.b < y.b
}

// Displaces each overlapping pair collected by the gravity traversal. Sorted
// first so the (order-dependent) resolution is deterministic.
@(private)
_collision_resolve :: proc(state: ^Physic_State, w: ^ecs.World) {
	pos := ecs.world_pool(w, Position).data
	radius := ecs.world_pool(w, Radius).data
	mass := ecs.world_pool(w, Mass).data

	found.profile_scope_args("collision.narrow", "pairs=%d", {len(state.collision_contacts)})
	slice.sort_by(state.collision_contacts[:], _contact_less)

	for contact in state.collision_contacts {
		a := contact.a
		b := contact.b

		dir := Vec3(pos[b]) - Vec3(pos[a])
		dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
		radius_sum := f32(radius[a]) + f32(radius[b])
		if dist_sq >= radius_sum * radius_sum || dist_sq <= 0.000001 {continue}
		dist := math.sqrt_f32(dist_sq)
		normal := dir / dist
		overlap := radius_sum - dist
		total_mass := f32(f64(mass[a]) + f64(mass[b]))
		pos[a] = Position(Vec3(pos[a]) - normal * (overlap * f32(mass[b]) / total_mass))
		pos[b] = Position(Vec3(pos[b]) + normal * (overlap * f32(mass[a]) / total_mass))
	}
}
