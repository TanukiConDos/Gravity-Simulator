package physics

import found "engine:foundation"
import ecs "engine:ecs"
import "base:intrinsics"
import "core:log"
import "core:math"
import "core:mem"
import "core:simd"
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
	// Bodies in the last version the reader successfully copied. Reader-private:
	// when no newer version is available it re-serves this count so the renderer
	// re-uploads the data it already holds instead of drawing a stale buffer.
	last_count: int,
}

// Set by the graphics thread after a pick readback and consumed by the physics
// thread, which is the only side allowed to touch the pools. A value of
// SELECTION_NONE means "no pending request".
SELECTION_NONE :: i32(-1)

Selection_State :: struct {
	picked: i32,
}

// Gravity solver hook. A tick submits a solve early and applies its results only
// when a consumer needs them, so the backend's work overlaps the CPU systems
// that do not depend on it:
//
//   - `physics_system_gravity` calls `submit`, which records and submits one
//     solve without waiting. Results stay in the backend's buffers; the pools
//     are not touched.
//   - `physics_system_collision` calls `finish` first when the backend's
//     contacts feed the narrow phase (the octree fold does; see
//     `finish_at_collision`).
//   - `physics_system_integrate` calls `finish` first otherwise, before the
//     position update that needs the new velocities.
//
// `finish` waits for the pending submission and applies its results: it writes
// the velocities into the pool (`vel += acc * dt` happened on the backend, so
// physics never integrates velocities for a hooked backend) and appends the
// contacts it found. It is idempotent; a false return uninstalls the hook and
// re-runs the CPU solver for the current tick. Tree backends read the tree from
// `physics_state(w)`.
Gravity_Submit_Proc :: proc(
	user: rawptr,
	w: ^ecs.World,
	bodies: []u32,
	seconds: f64,
) -> bool

Gravity_Finish_Proc :: proc(
	user: rawptr,
	w: ^ecs.World,
	bodies: []u32,
	contacts: ^[dynamic]Contact,
) -> bool

Gravity_Solver :: struct {
	user:   rawptr,
	submit: Gravity_Submit_Proc,
	finish: Gravity_Finish_Proc,
	// True when the narrow phase consumes the solve's contacts (the octree
	// fold): collision finishes the solve before resolving. False lets the
	// solve overlap the collision pass; integrate finishes it.
	finish_at_collision: bool,
	// Optional tree builder. While it is installed physics never builds the CPU
	// tree: the rebuild decision (interval/adaptive staleness) stays here, the
	// backend builds (on the GPU) and returns its metrics. A failed build
	// uninstalls the solver and the CPU builder takes over for good.
	build_tree: Tree_Build_Proc,
}

// Tree_Info summarizes a tree build. The adaptive controller, the tests and the
// bench read it instead of the tree, so a backend can own the tree entirely.
Tree_Info :: struct {
	node_count:        int,
	max_leaf_depth:    int,
	median_leaf_depth: int,
	typical_half:      f32,
	max_radius:        f32,
}

// Tree builder hook; see `Gravity_Solver.build_tree`.
Tree_Build_Proc :: proc(
	user: rawptr,
	w: ^ecs.World,
	bodies: []u32,
	max_depth: int,
	min_half: f32,
) -> (
	info: Tree_Info,
	ok: bool,
)

// Installs (or clears, with a zero value) the gravity solver. Call before the
// world is frozen; the physics thread reads it without synchronization.
physics_set_gravity_solver :: proc(w: ^ecs.World, solver: Gravity_Solver) {
	state := physics_state(w)
	state.gravity_solver = solver
	// Publish the liveness signal to the graphics thread. Only a solver that
	// owns the solve (`submit`) makes the backend active; a tree-only hook never
	// does, so the renderer keeps the snapshot.
	sync.atomic_store(&state.gravity_backend_active, solver.submit != nil)
}

// Solver/adaptive state lives as a world resource; the physics systems fetch it
// at the start of a tick and keep the pointer for their duration.
Physic_State :: struct {
	algorithm:           found.Algorithm,
	gravity_solver:      Gravity_Solver,
	// Atomic: true while a hooked backend owns the solve. The graphics thread
	// loads it to decide whether it may keep drawing the backend's render views
	// or must fall back to the snapshot; the physics thread stores it when the
	// hook is installed and clears it wherever a failed hook is uninstalled.
	gravity_backend_active: bool,
	// A hooked backend's submission is in flight between `physics.gravity` and
	// the first consumer (`physics.collision` or `physics.integrate`).
	gravity_pending:     bool,
	gravity_seconds:     f64,
	theta:               f32,
	rebuild_interval:    f32,
	max_depth:           int,
	min_half:            f32,
	tree:                ^OctTree,
	// True while the hooked backend owns the tree (built on the GPU); the CPU
	// tree is then nil and only `tree_info` is valid.
	tree_on_gpu:         bool,
	tree_info:           Tree_Info,
	tree_accumulator:    f32,
	tree_body_count:     int,
	tree_revision:       u64,
	collision_contacts:  [dynamic]Contact,
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
	s.last_count = 0
}

physics_state :: proc(w: ^ecs.World) -> ^Physic_State {
	state := ecs.world_resource(w, Physic_State, _state_destroy)
	assert(state != nil, "physics_state: resource missing (world frozen before physics_init?)")
	return state
}

// physics_gravity_backend_active reports whether a hooked gravity backend
// currently owns the solve. Safe to call from either thread: it is one atomic
// load, so the graphics thread can poll it without racing the physics thread.
// The renderer uses it to return to the snapshot path after a mid-run backend
// failure uninstalled the hook.
physics_gravity_backend_active :: proc(w: ^ecs.World) -> bool {
	state := physics_state(w)
	return sync.atomic_load(&state.gravity_backend_active)
}

physics_snapshot :: proc(w: ^ecs.World) -> ^RenderSnapshot {
	snapshot := ecs.world_resource(w, RenderSnapshot, _snapshot_destroy)
	assert(snapshot != nil, "physics_snapshot: resource missing (world frozen before physics_init?)")
	return snapshot
}

selection_state :: proc(w: ^ecs.World) -> ^Selection_State {
	state := ecs.world_resource(w, Selection_State)
	assert(state != nil, "selection_state: resource missing (world frozen before setup?)")
	return state
}

physics_init :: proc(w: ^ecs.World, config: found.Config) -> ^Physic_State {
	// Create every pool and resource up front so the physics and graphics
	// threads only ever read the registries concurrently.
	snap := ecs.world_resource(w, RenderSnapshot, _snapshot_destroy)
	snapshot_reserve(snap, max(w.capacity, body_count(w)))
	sel := ecs.world_resource(w, Selection_State)
	sel.picked = SELECTION_NONE
	s := ecs.world_resource(w, Physic_State, _state_destroy)
	s.algorithm = config.algorithm
	_physics_configure(s, config)
	s.ema_cost_ms = ADAPTIVE_HEADROOM * (1000.0 / max(config.target_tickrate, 1.0))
	s.warmup_left = ADAPTIVE_WARMUP
	_ = ecs.world_pool(w, Body)
	_ = ecs.world_pool(w, Position)
	_ = ecs.world_pool(w, Velocity)
	_ = ecs.world_pool(w, Acceleration)
	_ = ecs.world_pool(w, Mass)
	_ = ecs.world_pool(w, Radius)
	_ = ecs.world_pool(w, Selected)
	return s
}

// _physics_configure copies the live-tunable fields from `config`. The solver
// keeps its algorithmic choices (algorithm, depth) here too, but `algorithm` is
// set only at init because switching it needs a different solver hook.
@(private)
_physics_configure :: proc(s: ^Physic_State, config: found.Config) {
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
	if s.auto_adjust {
		s.theta = clamp(s.theta, s.theta_min, s.theta_max)
	}
}

// physics_reload_config applies a hot-reloaded config on the physics thread and
// invalidates the octree so the next gravity tick rebuilds with the new theta /
// depth / cell size even when the body count and world revision are unchanged.
physics_reload_config :: proc(w: ^ecs.World, config: found.Config) {
	s := physics_state(w)
	_physics_configure(s, config)
	s.warmup_left = ADAPTIVE_WARMUP
	s.tree_body_count = -1
	s.tree_revision = 0
	log.infof(
		"[PHYSIC] Reloaded tunables: theta=%.3f, rebuild=%.1f, max_depth=%d, auto_adjust=%v",
		s.theta,
		s.rebuild_interval,
		s.max_depth,
		s.auto_adjust,
	)
}

// Registers the physics systems as the PHYSICS phase. Dependencies are declared
// with handles rather than implied by registration order; `integrate` and
// `select` touch disjoint columns and may share a wave.
physics_register_systems :: proc(s: ^ecs.Scheduler) {
	begin := ecs.scheduler_add(s, "physics.begin", .PHYSICS, physics_system_begin)
	gravity := ecs.scheduler_add(
		s,
		"physics.gravity",
		.PHYSICS,
		physics_system_gravity,
		after = {begin},
	)
	collision := ecs.scheduler_add(
		s,
		"physics.collision",
		.PHYSICS,
		physics_system_collision,
		after = {gravity},
	)
	integrate := ecs.scheduler_add(
		s,
		"physics.integrate",
		.PHYSICS,
		physics_system_integrate,
		after = {collision},
		access = ecs.System_Access {
			reads = {typeid_of(Velocity), typeid_of(Physic_State)},
			writes = {typeid_of(Position), typeid_of(Physic_State)},
		},
		affinity = .ANY,
	)
	select := ecs.scheduler_add(
		s,
		"physics.select",
		.PHYSICS,
		physics_system_select,
		after = {collision},
		access = ecs.System_Access {
			reads = {typeid_of(Selection_State), typeid_of(Body)},
			writes = {typeid_of(Selected)},
		},
		affinity = .ANY,
	)
	publish := ecs.scheduler_add(
		s,
		"physics.publish",
		.PHYSICS,
		physics_system_publish,
		after = {integrate, select},
	)
	ecs.scheduler_add(s, "physics.adapt", .PHYSICS, physics_system_adapt, after = {publish})
}

physics_system_begin :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physics_state(w)
	// Stamp the tick even when there is nothing to do: an emptied world must
	// not leave a stale/zero `tick_start` behind, or the first cost measured
	// after bodies return would span the whole idle period.
	state.tick_start = time.tick_now()
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return true}

	acc := ecs.world_pool(w, Acceleration).data
	for idx in bodies {acc[idx] = Acceleration(Vec3{0, 0, 0})}

	if state.algorithm == .OCTREE {
		found.profile_scope("tree.ensure")
		_ensure_tree(state, w, delta_time)
	}
	return true
}

physics_system_gravity :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physics_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if len(bodies) == 0 {return true}
	seconds := f64(delta_time)

	switch state.algorithm {
	case .BRUTE_FORCE:
		if state.gravity_solver.submit != nil {
			found.profile_scope_args("gpu.submit", "n=%d", {len(bodies)})
			if _submit_gravity(state, w, bodies, seconds) {return true}
		}
		found.profile_scope_args("brute.force", "n=%d", {len(bodies)})
		_brute_force_solve(w, bodies, seconds)
	case .OCTREE:
		if state.tree != nil || state.tree_on_gpu {
			if state.tree != nil {state.tree.theta = state.theta}
			// The gravity traversal doubles as the collision broad phase:
			// positions do not change between the two phases, so the contacts
			// it collects are exactly what a separate pass would have found.
			// The collision sphere is inflated by the tree's build-time max
			// radius, so the query never hides a contact.
			clear(&state.collision_contacts)
			if state.gravity_solver.submit != nil {
				found.profile_scope_args("gpu.submit", "n=%d theta=%.2f", {len(bodies), state.theta})
				if _submit_gravity(state, w, bodies, seconds) {return true}
			}
			_octree_cpu_solve(state, w, bodies, seconds)
		}
	}
	return true
}

// _uninstall_gravity_solver drops the hook and clears the backend-active signal
// together, so the graphics thread can never observe a stale "active" while the
// solver is gone (and it cannot miss the clear when a failure path forgets one
// of the two stores).
@(private)
_uninstall_gravity_solver :: proc(state: ^Physic_State) {
	state.gravity_solver = {}
	sync.atomic_store(&state.gravity_backend_active, false)
}

// _submit_gravity starts one hooked solve. On failure the hook is dropped and
// the caller runs the CPU solver for this tick; the backend must not have
// touched the pools. A hook with only one of the two callbacks can never be
// completed (`_finish_gravity` would dereference a nil finish), so it is
// rejected here exactly like a failed submit.
@(private)
_submit_gravity :: proc(state: ^Physic_State, w: ^ecs.World, bodies: []u32, seconds: f64) -> bool {
	if state.gravity_solver.submit == nil || state.gravity_solver.finish == nil {
		log.errorf(
			"[PHYSIC] Gravity solver is incomplete (submit=%v finish=%v); falling back to the CPU solver",
			state.gravity_solver.submit != nil,
			state.gravity_solver.finish != nil,
		)
		_uninstall_gravity_solver(state)
		return false
	}
	if state.gravity_solver.submit(state.gravity_solver.user, w, bodies, seconds) {
		state.gravity_pending = true
		state.gravity_seconds = seconds
		return true
	}
	log.errorf("[PHYSIC] Gravity solver failed to submit; falling back to the CPU solver")
	_uninstall_gravity_solver(state)
	return false
}

// _finish_gravity completes a pending submission: it waits, scatters the
// velocities the backend computed and appends its contacts. Called by whichever
// system needs the results first; `gravity_pending` keeps it idempotent. When
// the backend fails, its pools are untouched, so the CPU solver can still
// produce this tick's gravity.
@(private)
_finish_gravity :: proc(state: ^Physic_State, w: ^ecs.World, bodies: []u32) {
	state.gravity_pending = false
	// Defensive: `_submit_gravity` refuses a nil finish, so this only triggers
	// if a caller installs a half-specified hook by hand. Keep the CPU fallback
	// instead of dereferencing it.
	if state.gravity_solver.finish == nil {
		log.errorf("[PHYSIC] Gravity solver has no finish callback; falling back to the CPU solver")
		_uninstall_gravity_solver(state)
		clear(&state.collision_contacts)
		_gravity_cpu_fallback(state, w, bodies)
		return
	}
	if state.gravity_solver.finish(
		state.gravity_solver.user,
		w,
		bodies,
		&state.collision_contacts,
	) {
		return
	}
	log.errorf("[PHYSIC] Gravity solver failed; falling back to the CPU solver")
	_uninstall_gravity_solver(state)
	clear(&state.collision_contacts)
	_gravity_cpu_fallback(state, w, bodies)
}

// _gravity_cpu_fallback re-solves the current tick with the CPU backend after a
// hooked solve was rejected or failed. The backend must not have touched the
// pools, so this produces the results the hook would have.
@(private)
_gravity_cpu_fallback :: proc(state: ^Physic_State, w: ^ecs.World, bodies: []u32) {
	switch state.algorithm {
	case .BRUTE_FORCE:
		// The finish usually happens after this tick's collision pass when the
		// brute-force backend is hooked; the fallback then solves gravity from
		// the post-collision positions. Only a device failure reaches here.
		_brute_force_solve(w, bodies, state.gravity_seconds)
	case .OCTREE:
		_octree_cpu_solve(state, w, bodies, state.gravity_seconds)
	}
}

// _octree_cpu_solve runs the CPU octree solve and builds or refreshes the CPU
// tree. The lazy build happens when a GPU backend fails after physics stopped
// building the CPU tree, but it is also the normal CPU path. A tree that does
// not match the world (nil, different body count, or a different world
// revision) is rebuilt with the same staleness predicate as `_ensure_tree`, so
// the fallback can never reuse a tree built for a different body set.
@(private)
_octree_cpu_solve :: proc(state: ^Physic_State, w: ^ecs.World, bodies: []u32, seconds: f64) {
	state.tree_on_gpu = false
	view := body_view(w)
	have := state.tree != nil
	stale := !have || state.tree_body_count != len(bodies) || state.tree_revision != w.revision
	if stale {
		found.profile_scope("octree.build")
		if state.tree != nil {
			octtree_rebuild_ex(state.tree, view, state.theta, state.max_depth, state.min_half)
		} else {
			state.tree = octtree_create_ex(view, state.theta, state.max_depth, state.min_half)
		}
		state.tree_info = _tree_info(state.tree)
		_tree_build_bookkeeping(state, w, view, bodies)
	} else {
		state.tree.view = view
	}
	state.tree.theta = state.theta
	_octree_solve(state, bodies, seconds)
}

// physics_finish_gravity completes a pending hooked solve and applies its
// results. The systems call it internally; benches and tests that drive the
// solve steps directly use it too.
physics_finish_gravity :: proc(w: ^ecs.World) {
	state := physics_state(w)
	if !state.gravity_pending {return}
	_finish_gravity(state, w, ecs.world_pool(w, Body).dense[:])
}

physics_system_collision :: proc(w: ^ecs.World, _: f32) -> bool {
	state := physics_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]

	// The octree fold produces the contacts this phase resolves, so the hooked
	// solve has to complete first. The brute-force solve does not feed
	// collision, so it stays in flight through this pass.
	if state.gravity_pending && state.gravity_solver.finish_at_collision {
		_finish_gravity(state, w, bodies)
	}
	if len(bodies) < 2 {return true}

	switch state.algorithm {
	case .BRUTE_FORCE:
		found.profile_scope_args("brute.collision", "n=%d", {len(bodies)})
		_brute_force_collision(w, bodies)
	case .OCTREE:
		if state.tree != nil || state.tree_on_gpu {_collision_resolve(state, w)}
	}
	return true
}

physics_system_integrate :: proc(w: ^ecs.World, delta_time: f32) -> bool {
	state := physics_state(w)
	bodies := ecs.world_pool(w, Body).dense[:]
	if state.gravity_pending {
		found.profile_scope_args("gpu.finish", "n=%d", {len(bodies)})
		_finish_gravity(state, w, bodies)
	}
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
// miss and simply clears the selection. The pick is consumed with an atomic
// exchange, so a newer pick stored between a load and a store can never be
// dropped.
physics_system_select :: proc(w: ^ecs.World, _: f32) -> bool {
	sel := selection_state(w)
	picked := sync.atomic_exchange(&sel.picked, SELECTION_NONE)
	if picked == SELECTION_NONE {return true}

	found.profile_scope_args("physics.select", "picked=%d", {picked})
	view := body_view(w)
	for idx in view.bodies {view.selected[idx] = Selected(false)}
	if picked >= 0 && int(picked) < len(view.bodies) {
		view.selected[view.bodies[int(picked)]] = Selected(true)
	}
	return true
}

physics_system_publish :: proc(w: ^ecs.World, _: f32) -> bool {
	found.profile_scope_args("snapshot.publish", "n=%d", {len(ecs.world_pool(w, Body).dense)})
	physics_snapshot_publish(w)
	return true
}

physics_system_adapt :: proc(w: ^ecs.World, _: f32) -> bool {
	state := physics_state(w)
	if len(ecs.world_pool(w, Body).dense) == 0 {return true}
	cost_ms := f32(
		time.duration_milliseconds(time.tick_diff(state.tick_start, time.tick_now())),
	)
	found.profile_scope_args(
		"physics.adapt",
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
	have := state.tree != nil || state.tree_on_gpu
	stale := !have || state.tree_body_count != len(bodies) || state.tree_revision != w.revision

	if !stale {
		if state.auto_adjust && have {
			state.tree_accumulator += delta_time
			if state.tree_accumulator >= state.rebuild_interval ||
			   adaptive_tree_stale(
				   state.max_disp_sq,
				   state.tree_info.typical_half,
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
		if state.gravity_solver.build_tree != nil {
			info, ok := state.gravity_solver.build_tree(
				state.gravity_solver.user,
				w,
				bodies,
				state.max_depth,
				state.min_half,
			)
			if ok {
				state.tree_info = info
				state.tree_on_gpu = true
				_tree_build_bookkeeping(state, w, view, bodies)
				found.profile_mark(
					"octree.built",
					"n=%d nodes=%d med_depth=%d max_depth=%d typical_half=%.4g rebuilds=%d source=gpu",
					{
						len(bodies),
						info.node_count,
						info.median_leaf_depth,
						info.max_leaf_depth,
						info.typical_half,
						state.rebuild_count,
					},
				)
				return nil
			}
			log.errorf("[PHYSIC] GPU tree build failed; falling back to the CPU solver")
			_uninstall_gravity_solver(state)
			state.tree_on_gpu = false
		}
		if state.tree != nil {
			octtree_rebuild_ex(state.tree, view, state.theta, state.max_depth, state.min_half)
		} else {
			state.tree = octtree_create_ex(view, state.theta, state.max_depth, state.min_half)
		}
		state.tree_on_gpu = false
		state.tree_info = _tree_info(state.tree)
		_tree_build_bookkeeping(state, w, view, bodies)
		found.profile_mark(
			"octree.built",
			"n=%d nodes=%d med_depth=%d max_depth=%d typical_half=%.4g rebuilds=%d source=cpu",
			{
				len(bodies),
				state.tree_info.node_count,
				state.tree_info.median_leaf_depth,
				state.tree_info.max_leaf_depth,
				state.tree_info.typical_half,
				state.rebuild_count,
			},
		)
	}
	state.updates_since_build += 1
	if state.tree != nil {state.tree.view = view}
	return state.tree
}

// _tree_build_bookkeeping records that the tree now matches the world. Shared by
// the CPU builder, the backend build hook and the adaptive staleness logic.
@(private)
_tree_build_bookkeeping :: proc(state: ^Physic_State, w: ^ecs.World, view: Bodies, bodies: []u32) {
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

@(private)
_tree_info :: proc(tree: ^OctTree) -> Tree_Info {
	return Tree_Info {
		node_count = tree.node_count,
		max_leaf_depth = tree.max_leaf_depth,
		median_leaf_depth = tree.median_leaf_depth,
		typical_half = tree.typical_half,
		max_radius = tree.max_radius,
	}
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
physics_snapshot_publish :: proc(w: ^ecs.World) {
	when !ODIN_DEBUG {
		// A healthy hooked backend owns the render path: the renderer draws the
		// backend's buffers directly and never reads the snapshot, so the
		// per-tick O(N) copy is dead work. Debug builds always publish because
		// `_backend_verify_direct` compares the direct instances against this
		// snapshot as its reference. The flag clears when the hook is dropped,
		// which re-enables publishing on the CPU fallback automatically.
		if physics_gravity_backend_active(w) {return}
	}
	snapshot := physics_snapshot(w)
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
//
// When no newer version is available (for example the renderer runs faster than
// the simulation, or another thread already consumed this version) it returns
// the last count without touching `dest`, which still holds that version: the
// caller can re-upload it instead of drawing stale data. Returning 0 here means
// "nothing has ever been published".
physics_snapshot_read :: proc(
	snapshot: ^RenderSnapshot,
	dest: rawptr,
	dest_selected: rawptr,
	max_count: int,
) -> int {
	for _ in 0 ..< 8 {
		p := sync.atomic_load(&snapshot.published)
		if p < 0 {return snapshot.last_count}
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
		snapshot.last_count = n
		return n
	}
	return snapshot.last_count
}

// Zero-mass bodies cannot be accelerated: the gravity update divides the pair
// force by the accelerated body's mass, so a zero divisor yields NaN. Two
// massless bodies also cannot be separated by the collision resolve, which
// divides the overlap by the pair's total mass. Both cases skip the
// interaction; the first one is reported so a bad scene is visible without
// spamming a log line per pair per tick. `_apply_gravity` runs on parallel
// workers, hence the atomic.
@(private)
_zero_mass_warned: u32

@(private)
_warn_zero_mass_once :: proc(context_name: string) {
	expected := u32(0)
	if _, swapped := sync.atomic_compare_exchange_strong(
		&_zero_mass_warned,
		expected,
		u32(1),
	); swapped {
		log.warnf(
			"[PHYSIC] zero-mass body skipped in %s instead of dividing by zero",
			context_name,
		)
	}
}

// Width of the brute-force SIMD inner step, in f32 lanes. Eight lanes is one
// AVX2 register (one AVX-512 register on a `-microarch:native` build); on a
// narrower target LLVM splits it into two SSE vectors, so the loop stays
// correct, just less wide. The accumulation order is fixed by the tile walk
// and the bisect reduction, so the result is deterministic.
BRUTE_SIMD_LANES :: 8

@(private)
_brute_splat :: #force_inline proc(v: f32) -> #simd[BRUTE_SIMD_LANES]f32 {
	return {v, v, v, v, v, v, v, v}
}

// The SoA columns are plain `[]f32`, so a vector load can land on any 4-byte
// offset (the tile start moves with `i`). Load/store unaligned explicitly
// instead of letting the `^#simd` deref imply the vector's natural alignment.
@(private)
_brute_load :: #force_inline proc(p: ^f32) -> #simd[BRUTE_SIMD_LANES]f32 {
	return intrinsics.unaligned_load((^#simd[BRUTE_SIMD_LANES]f32)(p))
}

@(private)
_brute_store :: #force_inline proc(p: ^f32, v: #simd[BRUTE_SIMD_LANES]f32) {
	intrinsics.unaligned_store((^#simd[BRUTE_SIMD_LANES]f32)(p), v)
}

// Tiled, SIMD all-pairs gravity. The scalar reference read every column
// through the entity index (`dir := pos[j] - pos[i]`), which forces the
// inner loop to issue three separate AoS loads per pair. Here the body
// columns are transposed once into a SoA scratch indexed by position in
// `bodies`, so the inner step loads a whole vector of `j` with one
// contiguous load and computes eight pairs per `sqrt`/divide.
//
// Numeric notes:
//  - The scalar form already widened an f32 distance to f64 before the
//    `sqrt`; eight f32 lanes use an f32 `sqrt` instead. The relative
//    difference is ~1e-7 and is measured against the GPU parity gates.
//  - The cancelled form `G*m_other / dist_sq` (as in the GPU kernels) is
//    kept: the f64 `G*m1*m2` numerator would overflow f32, while this form
//    fits. The accelerated body's mass cancels for positive masses.
//  - Newton's third law keeps the kick/symmetry structure: body `i` gains
//    the pair's pull and body `j` loses it, accumulated in place.
_brute_force_solve :: proc(w: ^ecs.World, bodies: []u32, seconds: f64) {
	pos := ecs.world_pool(w, Position).data
	vel := ecs.world_pool(w, Velocity).data
	acc := ecs.world_pool(w, Acceleration).data
	mass := ecs.world_pool(w, Mass).data
	n := len(bodies)
	if n < 2 {return}

	// Seven SoA columns: position (x, y, z), mass, and the running
	// acceleration (x, y, z), each indexed by the position in `bodies`.
	scratch := make([]f32, 7 * n)
	defer delete(scratch)
	sx := scratch[0 * n:1 * n]
	sy := scratch[1 * n:2 * n]
	sz := scratch[2 * n:3 * n]
	sm := scratch[3 * n:4 * n]
	ax := scratch[4 * n:5 * n]
	ay := scratch[5 * n:6 * n]
	az := scratch[6 * n:7 * n]

	for k in 0 ..< n {
		e := bodies[k]
		p := Vec3(pos[e])
		a := Vec3(acc[e])
		sx[k] = p.x
		sy[k] = p.y
		sz[k] = p.z
		sm[k] = f32(mass[e])
		ax[k] = a.x
		ay[k] = a.y
		az[k] = a.z
	}

	dt := f32(seconds)
	g_vec := _brute_splat(f32(GRAVITY_CONSTANT))
	eps := _brute_splat(1e-6)
	one := _brute_splat(1.0)
	zero: #simd[BRUTE_SIMD_LANES]f32 = {0, 0, 0, 0, 0, 0, 0, 0}

	for ii in 0 ..< n {
		px := sx[ii]
		py := sy[ii]
		pz := sz[ii]
		m_i := sm[ii]
		m_i_vec := _brute_splat(m_i)
		// One vector accumulator per component, reduced once per body instead
		// of once per tile. The lanes hold different `j`, so the reduction
		// mixes them; the bisect tree is fixed, hence deterministic.
		avx := zero
		avy := zero
		avz := zero
		jj := ii + 1
		for ; jj + BRUTE_SIMD_LANES <= n; jj += BRUTE_SIMD_LANES {
			dx := _brute_load(&sx[jj]) - _brute_splat(px)
			dy := _brute_load(&sy[jj]) - _brute_splat(py)
			dz := _brute_load(&sz[jj]) - _brute_splat(pz)
			dist_sq := dx * dx + dy * dy + dz * dz
			dist_sq = simd.max(dist_sq, eps)
			g_over := g_vec / dist_sq
			// acc = dir * (G / dist_sq) * m_other; inv folds the sqrt and the
			// normalisation into the vector unit.
			dir_scale := (one / simd.sqrt(dist_sq)) * g_over
			bx := dx * dir_scale
			by := dy * dir_scale
			bz := dz * dir_scale
			m_j := _brute_load(&sm[jj])
			avx += bx * m_j
			avy += by * m_j
			avz += bz * m_j
			_brute_store(&ax[jj], _brute_load(&ax[jj]) - bx * m_i_vec)
			_brute_store(&ay[jj], _brute_load(&ay[jj]) - by * m_i_vec)
			_brute_store(&az[jj], _brute_load(&az[jj]) - bz * m_i_vec)
		}
		acc_ix := ax[ii] + simd.reduce_add_bisect(avx)
		acc_iy := ay[ii] + simd.reduce_add_bisect(avy)
		acc_iz := az[ii] + simd.reduce_add_bisect(avz)
		// Scalar tail for the last <BRUTE_SIMD_LANES bodies; same cancelled
		// form so both paths agree.
		for ; jj < n; jj += 1 {
			dx := sx[jj] - px
			dy := sy[jj] - py
			dz := sz[jj] - pz
			dist_sq := dx * dx + dy * dy + dz * dz
			if dist_sq < 1e-6 {dist_sq = 1e-6}
			dir_scale := (1.0 / math.sqrt_f32(dist_sq)) * (f32(GRAVITY_CONSTANT) / dist_sq)
			bx := dx * dir_scale
			by := dy * dir_scale
			bz := dz * dir_scale
			acc_ix += bx * sm[jj]
			acc_iy += by * sm[jj]
			acc_iz += bz * sm[jj]
			ax[jj] -= bx * m_i
			ay[jj] -= by * m_i
			az[jj] -= bz * m_i
		}
		ax[ii] = acc_ix
		ay[ii] = acc_iy
		az[ii] = acc_iz
		i := bodies[ii]
		vel[i] = Velocity(Vec3(vel[i]) + Vec3{acc_ix, acc_iy, acc_iz} * dt)
	}

	for k in 0 ..< n {
		acc[bodies[k]] = Acceleration(Vec3{ax[k], ay[k], az[k]})
	}
}

// A brute-collision candidate stores the two positions its bodies hold in the
// dense `bodies` list, not entity indices. The serial loop resolved pairs in
// `(ii, jj)` lexicographic order over that list and moved both bodies in place,
// so the parallel path has to reproduce that order exactly to stay bit-identical.
_BrutePair :: struct {
	ii: u32,
	jj: u32,
}

@(private)
_brute_pair_less :: proc(x, y: _BrutePair) -> bool {
	if x.ii != y.ii {return x.ii < y.ii}
	return x.jj < y.jj
}

// The overlap predicate and the weighted separation are the serial loop's,
// factored out so the broad phase, the replay's created-contact scan and the
// fallback cannot drift apart.
@(private)
_brute_pairs_overlap :: #force_inline proc(
	pos: []Position,
	radius: []Radius,
	a, b: u32,
) -> bool {
	dir := Vec3(pos[b]) - Vec3(pos[a])
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	radius_sum := f32(radius[a]) + f32(radius[b])
	return dist_sq < radius_sum * radius_sum && dist_sq > 0.000001
}

// One serial narrow-phase step. Returns true when it displaced the bodies; a
// pair that has already separated, or that is massless, is not displaced (the
// serial loop skipped exactly those pairs the same way).
@(private)
_brute_apply_pair :: proc(
	pos: []Position,
	radius: []Radius,
	mass: []Mass,
	a, b: u32,
) -> bool {
	dir := Vec3(pos[b]) - Vec3(pos[a])
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	radius_sum := f32(radius[a]) + f32(radius[b])
	if dist_sq >= radius_sum * radius_sum || dist_sq <= 0.000001 {return false}
	dist := math.sqrt_f32(dist_sq)
	normal := dir / dist
	overlap := radius_sum - dist
	total_mass := f32(f64(mass[a]) + f64(mass[b]))
	if total_mass == 0 {
		// Two massless bodies: the weighted separation is 0/0.
		_warn_zero_mass_once("collision")
		return false
	}
	pos[a] = Position(Vec3(pos[a]) - normal * (overlap * f32(mass[b]) / total_mass))
	pos[b] = Position(Vec3(pos[b]) + normal * (overlap * f32(mass[a]) / total_mass))
	return true
}

// The original serial O(N^2) pass, kept verbatim as the reference the parallel
// path must reproduce and as the fallback for a snapshot whose contact list is
// large enough that the replay's per-resolve rescan would cost more than this.
@(private)
_brute_force_collision_serial :: proc(
	pos: []Position,
	radius: []Radius,
	mass: []Mass,
	bodies: []u32,
) {
	for ii in 0 ..< len(bodies) {
		a := bodies[ii]
		for jj in ii + 1 ..< len(bodies) {
			_brute_apply_pair(pos, radius, mass, a, bodies[jj])
		}
	}
}

_BruteBroadData :: struct {
	pos:        []Position,
	radius:     []Radius,
	bodies:     []u32,
	n:          int,
	chunk_size: int,
	chunks:     [][dynamic]_BrutePair,
}

// One broad-phase work chunk: rows [start, end) of the serial loop, scanning
// each row's `jj > ii` tail. A chunk is owned by one task, so its list needs no
// lock; chunk order is fixed by the caller, so merging the lists in order
// reproduces the serial pair order without a sort.
@(private)
_brute_broad_chunk :: proc(chunk_index: int, data: rawptr) {
	ctx := cast(^_BruteBroadData)data
	start := chunk_index * ctx.chunk_size
	end := min(start + ctx.chunk_size, ctx.n)
	pairs := &ctx.chunks[chunk_index]
	for ii in start ..< end {
		a := ctx.bodies[ii]
		for jj in ii + 1 ..< ctx.n {
			if _brute_pairs_overlap(ctx.pos, ctx.radius, a, ctx.bodies[jj]) {
				append(pairs, _BrutePair{u32(ii), u32(jj)})
			}
		}
	}
}

@(private)
_brute_heap_push :: proc(heap: ^[dynamic]_BrutePair, p: _BrutePair) {
	append(heap, p)
	i := len(heap) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !_brute_pair_less(heap[i], heap[parent]) {break}
		heap[i], heap[parent] = heap[parent], heap[i]
		i = parent
	}
}

@(private)
_brute_heap_pop :: proc(heap: ^[dynamic]_BrutePair) -> _BrutePair {
	top := heap[0]
	last := pop(heap)
	n := len(heap)
	if n > 0 {
		heap[0] = last
		i := 0
		for {
			l := 2 * i + 1
			r := l + 1
			small := i
			if l < n && _brute_pair_less(heap[l], heap[small]) {small = l}
			if r < n && _brute_pair_less(heap[r], heap[small]) {small = r}
			if small == i {break}
			heap[i], heap[small] = heap[small], heap[i]
			i = small
		}
	}
	return top
}

// Parallel brute-force collision. The broad phase scans every pair in parallel
// and collects the contacts present in the snapshot; the narrow phase then
// replays the serial loop in its exact `(ii, jj)` order. Because a resolve moves
// both bodies, it can push one of them into a *new* overlap that the serial loop
// goes on to resolve in the same row or a later one, so the replay rescans the
// two moved bodies after every displacement and queues any newly overlapping
// pair still ahead of the cursor. Testing the initial candidates and the created
// ones at their own order with the same arithmetic keeps the post-tick positions
// bit-identical to the serial loop regardless of how the broad phase was
// scheduled.
_brute_force_collision :: proc(w: ^ecs.World, bodies: []u32) {
	pos := ecs.world_pool(w, Position).data[:]
	radius := ecs.world_pool(w, Radius).data[:]
	mass := ecs.world_pool(w, Mass).data[:]
	n := len(bodies)
	if n < 2 {return}

	worker_count := found.parallel_worker_count()
	if worker_count <= 0 {worker_count = 1}
	chunk_target := worker_count * found.PARALLEL_CHUNKS_PER_WORKER
	if chunk_target > n {chunk_target = n}
	if chunk_target < 1 {chunk_target = 1}
	chunk_size := (n + chunk_target - 1) / chunk_target
	if chunk_size < 1 {chunk_size = 1}
	chunk_count := (n + chunk_size - 1) / chunk_size

	broad := _BruteBroadData {
		pos        = pos,
		radius     = radius,
		bodies     = bodies,
		n          = n,
		chunk_size = chunk_size,
		chunks     = make([][dynamic]_BrutePair, chunk_count),
	}
	defer {
		for k in 0 ..< chunk_count {delete(broad.chunks[k])}
		delete(broad.chunks)
	}
	found.job_system_parallel_chunks(
		found.default_job_system(),
		_brute_broad_chunk,
		&broad,
		chunk_count,
	)

	total := 0
	for k in 0 ..< chunk_count {total += len(broad.chunks[k])}
	if total == 0 {
		// No contact in the snapshot: the serial loop would test every pair and
		// move nothing, so the tick is already done.
		return
	}
	if total > n {
		// Dense snapshot: the replay rescans after every resolve, so a contact
		// list larger than the body count is cheaper to solve straight through.
		// Nothing has moved yet, so the plain serial pass is still exact.
		_brute_force_collision_serial(pos, radius, mass, bodies)
		return
	}

	// Exact replay. `tested` makes repeated candidates idempotent: a pair can
	// enter the heap from several scans, but the serial loop tested each pair
	// once, so later copies are dropped.
	heap := make([dynamic]_BrutePair, 0, total)
	defer delete(heap)
	for k in 0 ..< chunk_count {
		for p in broad.chunks[k] {_brute_heap_push(&heap, p)}
	}
	tested := make(map[u64]bool, total * 2)
	defer delete(tested)

	// Undo snapshot for the safety valve, only paid when the snapshot has
	// contacts.
	initial := make([]Position, n)
	defer delete(initial)
	for k in 0 ..< n {initial[k] = pos[bodies[k]]}

	// The replay may rescan after each of at most `total` initial contacts, but
	// a displacement can cascade. Cap the rescans at half a serial pass worth of
	// pair tests; past that the plain serial loop is both faster and known-good.
	scan_budget := n * n / 2
	scanned := 0
	overflow := false
	for len(heap) > 0 {
		p := _brute_heap_pop(&heap)
		key := (u64(p.ii) << 32) | u64(p.jj)
		if tested[key] {continue}
		tested[key] = true
		if !_brute_apply_pair(pos, radius, mass, bodies[p.ii], bodies[p.jj]) {
			continue
		}

		if scanned + 2 * n > scan_budget {
			overflow = true
			break
		}
		scanned += 2 * n
		// Both bodies moved; look for contacts the displacement created, keeping
		// only pairs the serial cursor has not passed yet.
		moved := [2]u32{p.ii, p.jj}
		for mi in moved {
			m := bodies[mi]
			for dc in 0 ..< n {
				if u32(dc) == mi {continue}
				oi, oj := u32(dc), mi
				if mi < oi {oi, oj = mi, oi}
				if oi < p.ii || (oi == p.ii && oj <= p.jj) {continue}
				if tested[(u64(oi) << 32) | u64(oj)] {continue}
				if _brute_pairs_overlap(pos, radius, m, bodies[dc]) {
					_brute_heap_push(&heap, _BrutePair{oi, oj})
				}
			}
		}
	}

	if overflow {
		for k in 0 ..< n {pos[bodies[k]] = initial[k]}
		_brute_force_collision_serial(pos, radius, mass, bodies)
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
	// One `[dynamic]Contact` per work chunk: a chunk is executed by exactly one
	// task, so its list needs no lock, and the per-pair mutex contention that
	// serialised dense-overlap scenes disappears. The lists are merged into the
	// (cleared) `state.collision_contacts` after the solve; `_collision_resolve`
	// still sorts the merged set, so determinism is unchanged.
	//
	// `job_system_parallel_chunks` takes the chunk list as the work unit and
	// derives its own task grouping from it. Sizing the chunk count to
	// `worker_count * PARALLEL_CHUNKS_PER_WORKER * PARALLEL_MIN_CHUNK` makes
	// that grouping collapse to the same task granularity `parallel_for` used
	// (see `job_system_parallel_chunks`), so sparse scenes keep their old
	// balance while dense ones stop contending.
	body_count := len(bodies)
	worker_count := found.parallel_worker_count()
	if worker_count <= 0 {worker_count = 1}
	chunk_target :=
		worker_count * found.PARALLEL_CHUNKS_PER_WORKER * found.PARALLEL_MIN_CHUNK
	if chunk_target > body_count {chunk_target = body_count}
	if chunk_target < 1 {chunk_target = 1}
	chunk_size := (body_count + chunk_target - 1) / chunk_target
	if chunk_size < 1 {chunk_size = 1}
	chunk_count := (body_count + chunk_size - 1) / chunk_size
	if chunk_count < 1 {chunk_count = 1}

	data := _OctreeSolveData {
		tree       = tree,
		indices    = bodies,
		dt         = f32(seconds),
		chunks     = make([][dynamic]Contact, chunk_count),
		chunk_size = chunk_size,
		body_count = body_count,
	}
	defer {
		for k in 0 ..< chunk_count {delete(data.chunks[k])}
		delete(data.chunks)
	}

	found.job_system_parallel_chunks(
		found.default_job_system(),
		_octree_solve_chunk,
		&data,
		chunk_count,
	)

	total := 0
	for k in 0 ..< chunk_count {total += len(data.chunks[k])}
	reserve(&state.collision_contacts, total)
	for k in 0 ..< chunk_count {
		append(&state.collision_contacts, ..data.chunks[k][:])
	}
	found.profile_mark("octree.solved", "pairs=%d", {len(state.collision_contacts)})
}

_OctreeSolveData :: struct {
	tree:       ^OctTree,
	indices:    []u32,
	dt:         f32,
	chunks:     [][dynamic]Contact,
	chunk_size: int,
	body_count: int,
}

// Runs every body query in one work chunk, appending contacts to the chunk's
// private list (nil mutex: this list is owned by this single task).
_octree_solve_chunk :: proc(chunk_index: int, data: rawptr) {
	ctx := cast(^_OctreeSolveData)data
	start := chunk_index * ctx.chunk_size
	end := min(start + ctx.chunk_size, ctx.body_count)
	contacts := &ctx.chunks[chunk_index]
	for i in start ..< end {
		_calc_force_collect(ctx.tree, ctx.indices[i], ctx.tree.theta, ctx.dt, contacts, nil)
	}
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
		if total_mass == 0 {
			// Two massless bodies: the weighted separation is 0/0.
			_warn_zero_mass_once("collision")
			continue
		}
		pos[a] = Position(Vec3(pos[a]) - normal * (overlap * f32(mass[b]) / total_mass))
		pos[b] = Position(Vec3(pos[b]) + normal * (overlap * f32(mass[a]) / total_mass))
	}
}
