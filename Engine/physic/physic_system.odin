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

RenderSnapshot :: struct {
	mutex:    sync.Mutex,
	data:     [dynamic]Vec3,
	selected: [dynamic]u8,
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
	delete(s.data)
	delete(s.selected)
	free(ptr)
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
	_ = ecs.world_resource(w, RenderSnapshot, _snapshot_destroy)
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

// Registered in this order; the scheduler runs them as the PHYSICS phase.
physic_register_systems :: proc(s: ^ecs.Scheduler) {
	ecs.scheduler_add(s, "physic.begin", .PHYSICS, physic_system_begin)
	ecs.scheduler_add(s, "physic.gravity", .PHYSICS, physic_system_gravity)
	ecs.scheduler_add(s, "physic.collision", .PHYSICS, physic_system_collision)
	ecs.scheduler_add(s, "physic.integrate", .PHYSICS, physic_system_integrate)
	ecs.scheduler_add(s, "physic.select", .PHYSICS, physic_system_select)
	ecs.scheduler_add(s, "physic.publish", .PHYSICS, physic_system_publish)
	ecs.scheduler_add(s, "physic.adapt", .PHYSICS, physic_system_adapt)
}

physic_system_begin :: proc(w: ^ecs.World, delta_time: f32) {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return}
	state.tick_start = time.tick_now()

	acc := ecs.world_pool(w, Acceleration).data
	for idx in bodies {acc[idx] = Acceleration(Vec3{0, 0, 0})}

	if state.algorithm == .OCTREE {
		_ensure_tree(state, w, delta_time)
	}
}

physic_system_gravity :: proc(w: ^ecs.World, delta_time: f32) {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return}
	seconds := f64(delta_time)

	switch state.algorithm {
	case .BRUTE_FORCE:
		_brute_force_solve(w, bodies, seconds)
	case .OCTREE:
		if state.tree != nil {
			state.tree.theta = state.theta
			// The gravity traversal doubles as the collision broad phase:
			// positions do not change between the two phases, so the contacts
			// it collects are exactly what a separate pass would have found.
			clear(&state.collision_contacts)
			max_radius: f32
			radius := ecs.world_pool(w, Radius).data
			for idx in bodies {
				r := f32(radius[idx])
				if r > max_radius {max_radius = r}
			}
			_octree_solve(state, bodies, seconds, max_radius)
		}
	}
}

physic_system_collision :: proc(w: ^ecs.World, _: f32) {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) < 2 {return}

	switch state.algorithm {
	case .BRUTE_FORCE:
		_brute_force_collision(w, bodies)
	case .OCTREE:
		if state.tree != nil {_collision_resolve(state, w)}
	}
}

physic_system_integrate :: proc(w: ^ecs.World, delta_time: f32) {
	state := physic_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return}

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
}

// Applies a pick result handed over by the graphics thread. Runs on the physics
// thread, which owns the Selected pool; an out-of-range index is treated as a
// miss and simply clears the selection.
physic_system_select :: proc(w: ^ecs.World, _: f32) {
	sel := selection_state(w)
	picked := sync.atomic_load(&sel.picked)
	if picked == SELECTION_NONE {return}
	sync.atomic_store(&sel.picked, SELECTION_NONE)

	view := body_view(w)
	for idx in view.bodies {view.selected[idx] = Selected(false)}
	if picked >= 0 && int(picked) < len(view.bodies) {
		view.selected[view.bodies[int(picked)]] = Selected(true)
	}
}

physic_system_publish :: proc(w: ^ecs.World, _: f32) {
	physic_snapshot_publish(w)
}

physic_system_adapt :: proc(w: ^ecs.World, _: f32) {
	state := physic_state(w)
	if len(ecs.world_pool(w, Body).dense) == 0 {return}
	cost_ms := f32(
		time.duration_milliseconds(time.tick_diff(state.tick_start, time.tick_now())),
	)
	_adaptive_controller(state, cost_ms)
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

	state.theta = new_theta
	state.cooldown_left = ADAPTIVE_COOLDOWN
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

physic_snapshot_publish :: proc(w: ^ecs.World) {
	snapshot := physic_snapshot(w)
	view := body_view(w)
	count := len(view.bodies)
	sync.mutex_lock(&snapshot.mutex)
	resize(&snapshot.data, count)
	resize(&snapshot.selected, count)
	for i in 0 ..< count {
		entity := view.bodies[i]
		snapshot.data[i] = Vec3(view.position[entity])
		snapshot.selected[i] = bool(view.selected[entity]) ? 1 : 0
	}
	sync.mutex_unlock(&snapshot.mutex)
}

physic_snapshot_read :: proc(
	snapshot: ^RenderSnapshot,
	dest: rawptr,
	dest_selected: rawptr,
	max_count: int,
) -> int {
	sync.mutex_lock(&snapshot.mutex)
	n := min(max_count, len(snapshot.data))
	if n > 0 && dest != nil {
		mem.copy(dest, raw_data(snapshot.data), n * size_of(Vec3))
	}
	if n > 0 && dest_selected != nil {
		mem.copy(dest_selected, raw_data(snapshot.selected), n)
	}
	sync.mutex_unlock(&snapshot.mutex)
	return n
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

_octree_solve :: proc(state: ^Physic_State, bodies: []u32, seconds: f64, max_radius: f32) {
	tree := state.tree
	if tree == nil {return}
	found.profile_scope("octree.solve")
	data := _OctreeSolveData {
		tree       = tree,
		indices    = bodies,
		dt         = f32(seconds),
		max_radius = max_radius,
		contacts   = &state.collision_contacts,
		mutex      = &state.collision_mutex,
	}
	found.parallel_for(_octree_solve_worker, &data, len(bodies))
}

_OctreeSolveData :: struct {
	tree:       ^OctTree,
	indices:    []u32,
	dt:         f32,
	max_radius: f32,
	contacts:   ^[dynamic]Contact,
	mutex:      ^sync.Mutex,
}

_octree_solve_worker :: proc(index: int, data: rawptr) {
	ctx := cast(^_OctreeSolveData)data
	octtree_calc_force_and_collect(
		ctx.tree,
		ctx.indices[index],
		ctx.dt,
		ctx.max_radius,
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

	slice.sort_by(state.collision_contacts[:], _contact_less)

	found.profile_scope("collision.narrow")
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
