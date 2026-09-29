package tests

import ecs "../Engine/ecs"
import found "../foundation"
import "core:log"
import "core:sync"
import "core:testing"

@(private)
Test_Position :: struct {
	x, y, z: f32,
}

@(private)
Test_Velocity :: struct {
	x, y, z: f32,
}

@(private)
Test_Probe :: struct {
	value: int,
}

// A second singleton type for the freeze tests, so they do not share the
// `g_probe_destroyed` counter with `test_ecs_resource` (tests run concurrently).
@(private)
Test_Singleton :: struct {
	value: int,
}

@(private)
g_probe_destroyed: int

@(private)
_probe_destroy :: proc(ptr: rawptr) {
	g_probe_destroyed += 1
	free(ptr)
}

@(test)
test_ecs_spawn_despawn :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	a := ecs.world_spawn(w)
	b := ecs.world_spawn(w)
	testing.expect(t, a.index != b.index, "spawned indices must differ")
	testing.expect(t, ecs.world_is_alive(w, a))
	testing.expect(t, ecs.world_is_alive(w, b))
	testing.expect_value(t, a.generation, u32(0))

	ecs.world_despawn(w, a)
	testing.expect(t, ecs.world_is_alive(w, a), "despawn is deferred until flush")
	ecs.world_flush(w)
	testing.expect(t, !ecs.world_is_alive(w, a), "flushed entity must be dead")

	c := ecs.world_spawn(w)
	testing.expect_value(t, c.index, a.index)
	testing.expect_value(t, c.generation, u32(1))
	testing.expect(t, ecs.world_is_alive(w, c))
	testing.expect(t, !ecs.world_is_alive(w, a), "stale handle must not alias the reused slot")
}

@(test)
test_ecs_components :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	e := ecs.world_spawn(w)
	ecs.world_set(w, e, Test_Position{1, 2, 3})
	ecs.world_set(w, e, Test_Velocity{4, 5, 6})

	pos := ecs.world_get(w, e, Test_Position)
	testing.expect(t, pos != nil)
	testing.expect_value(t, pos.x, f32(1))
	testing.expect_value(t, pos.y, f32(2))
	testing.expect_value(t, pos.z, f32(3))
	testing.expect(t, ecs.world_has(w, e, Test_Velocity))

	ecs.world_remove(w, e, Test_Velocity)
	testing.expect(t, !ecs.world_has(w, e, Test_Velocity))
	testing.expect(t, ecs.world_get(w, e, Test_Velocity) == nil)
	testing.expect(t, ecs.world_has(w, e, Test_Position), "removing one component keeps the other")
}

// Different components may be present on different entities; because pools are
// indexed by entity index their columns stay aligned independent of each other.
@(test)
test_ecs_pool_alignment :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	e0 := ecs.world_spawn(w)
	e1 := ecs.world_spawn(w)
	e2 := ecs.world_spawn(w)

	ecs.world_set(w, e0, Test_Position{0, 0, 0})
	ecs.world_set(w, e1, Test_Position{1, 0, 0})
	ecs.world_set(w, e2, Test_Position{2, 0, 0})

	ecs.world_set(w, e0, Test_Velocity{0, 0, 0})
	ecs.world_set(w, e2, Test_Velocity{2, 0, 0})

	pp := ecs.world_pool(w, Test_Position)
	vp := ecs.world_pool(w, Test_Velocity)

	testing.expect_value(t, len(pp.dense), 3)
	testing.expect_value(t, len(vp.dense), 2)
	testing.expect_value(t, pp.data[e1.index].x, f32(1))
	testing.expect_value(t, vp.data[e2.index].x, f32(2))
	testing.expect(t, ecs.pool_has(pp, e1.index))
	testing.expect(t, !ecs.pool_has(vp, e1.index))
}

@(test)
test_ecs_pool_remove_swap :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	entities: [4]ecs.Entity
	for i in 0 ..< 4 {
		entities[i] = ecs.world_spawn(w)
		ecs.world_set(w, entities[i], Test_Position{f32(i), 0, 0})
	}

	ecs.world_remove(w, entities[1], Test_Position)
	p := ecs.world_pool(w, Test_Position)
	testing.expect_value(t, len(p.dense), 3)
	testing.expect(t, !ecs.pool_has(p, entities[1].index))
	for i in 0 ..< 4 {
		if i == 1 {continue}
		testing.expect(t, ecs.pool_has(p, entities[i].index))
		testing.expect_value(t, ecs.world_get(w, entities[i], Test_Position).x, f32(i))
	}
}

@(test)
test_ecs_flush_clears_all_pools :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	e := ecs.world_spawn(w)
	ecs.world_set(w, e, Test_Position{1, 1, 1})
	ecs.world_set(w, e, Test_Velocity{2, 2, 2})

	ecs.world_despawn(w, e)
	ecs.world_flush(w)

	testing.expect_value(t, len(ecs.world_pool(w, Test_Position).dense), 0)
	testing.expect_value(t, len(ecs.world_pool(w, Test_Velocity).dense), 0)
	testing.expect_value(t, w.alive_count, 0)
}

@(test)
test_ecs_resource :: proc(t: ^testing.T) {
	g_probe_destroyed = 0
	w := ecs.world_create()

	first := ecs.world_resource(w, Test_Probe, _probe_destroy)
	second := ecs.world_resource(w, Test_Probe, _probe_destroy)
	testing.expect(t, first == second, "resource accessor must return the same singleton")

	ecs.world_destroy(w)
	testing.expect_value(t, g_probe_destroyed, 1)
}

@(private)
g_scheduler_order: [dynamic]u8

@(private)
_sys_a :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_scheduler_order, 'a'); return true}
@(private)
_sys_b :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_scheduler_order, 'b'); return true}
@(private)
_sys_r :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_scheduler_order, 'r'); return true}

// Separate log for the failure test: the runner executes tests concurrently, so
// tests must not share mutable globals.
@(private)
g_fail_order: [dynamic]u8

@(private)
_sys_fail_a :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_fail_order, 'a'); return true}
@(private)
_sys_fail_x :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_fail_order, 'x'); return false}
@(private)
_sys_fail_b :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_fail_order, 'b'); return true}

@(test)
test_ecs_scheduler_phase_order :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	ecs.scheduler_add(s, "a", .PHYSICS, _sys_a)
	ecs.scheduler_add(s, "r", .RENDER, _sys_r)
	ecs.scheduler_add(s, "b", .PHYSICS, _sys_b)

	delete(g_scheduler_order)
	g_scheduler_order = {}
	defer delete(g_scheduler_order)

	testing.expect(t, ecs.scheduler_run(s, .PHYSICS, w, 0.016), "phase succeeds")
	testing.expect_value(t, string(g_scheduler_order[:]), "ab")

	testing.expect(t, ecs.scheduler_run(s, .RENDER, w, 0.016), "render phase succeeds")
	testing.expect_value(t, string(g_scheduler_order[:]), "abr")
}

@(test)
test_ecs_scheduler_stops_on_failure :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	ecs.scheduler_add(s, "a", .PHYSICS, _sys_fail_a)
	ecs.scheduler_add(s, "fail", .PHYSICS, _sys_fail_x)
	ecs.scheduler_add(s, "b", .PHYSICS, _sys_fail_b)

	delete(g_fail_order)
	g_fail_order = {}
	defer delete(g_fail_order)

	testing.expect(t, !ecs.scheduler_run(s, .PHYSICS, w, 0.016), "failure is reported")
	testing.expect_value(t, string(g_fail_order[:]), "ax")
}

// A failure drops every system that has not started, including ones blocked on
// the failed system; the phase must still complete and report the failure.
@(private)
g_chain_order: [dynamic]u8

@(private)
_sys_chain_a :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_chain_order, 'a'); return true}
@(private)
_sys_chain_x :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_chain_order, 'x'); return false}
@(private)
_sys_chain_b :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_chain_order, 'b'); return true}

@(test)
test_ecs_scheduler_failure_chain :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	a := ecs.scheduler_add(s, "a", .PHYSICS, _sys_chain_a)
	x := ecs.scheduler_add(s, "x", .PHYSICS, _sys_chain_x, after = {a})
	ecs.scheduler_add(s, "b", .PHYSICS, _sys_chain_b, after = {x})

	delete(g_chain_order)
	g_chain_order = {}
	defer delete(g_chain_order)

	testing.expect(t, !ecs.scheduler_run(s, .PHYSICS, w, 0.016), "failure is reported")
	testing.expect_value(t, string(g_chain_order[:]), "ax")
}

@(private)
_has_edge :: proc(s: ^ecs.Scheduler, from, to: ecs.System_Handle) -> bool {
	for e in s.schedule[.PHYSICS].successors[int(from)] {
		if e == to {return true}
	}
	return false
}

// The graph carries the explicit `after` edges plus access-conflict edges
// between `.ANY` systems; it is the only ordering mechanism.
@(test)
test_ecs_scheduler_graph :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	a := ecs.scheduler_add(s, "a", .PHYSICS, _sys_a)
	b := ecs.scheduler_add(
		s,
		"b",
		.PHYSICS,
		_sys_b,
		after = {a},
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	c := ecs.scheduler_add(
		s,
		"c",
		.PHYSICS,
		_sys_r,
		after = {a},
		access = ecs.System_Access{writes = {typeid_of(Test_Velocity)}},
		affinity = .ANY,
	)
	d := ecs.scheduler_add(
		s,
		"d",
		.PHYSICS,
		_sys_a,
		after = {a},
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, _has_edge(s, a, b), "explicit edge a->b")
	testing.expect(t, _has_edge(s, a, c), "explicit edge a->c")
	testing.expect(t, _has_edge(s, a, d), "explicit edge a->d")
	testing.expect(t, _has_edge(s, b, d), "conflict edge b->d")
	testing.expect(t, !_has_edge(s, c, d), "disjoint access needs no edge")
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(b)], 1)
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(c)], 1)
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(d)], 2)
}

@(test)
test_ecs_scheduler_access_conflict_serializes :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	x := ecs.scheduler_add(
		s,
		"x",
		.PHYSICS,
		_sys_a,
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	y := ecs.scheduler_add(
		s,
		"y",
		.PHYSICS,
		_sys_b,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, _has_edge(s, x, y), "writer->reader edge serialises")
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(y)], 1)
}

// A `.CALLER` writer and an `.ANY` reader of the same component conflicted in
// the old graph only when both sides were `.ANY`, so the pair could run
// concurrently (the caller inline, the reader on the pool). The forward edge
// must be added for every affinity mix.
@(test)
test_ecs_scheduler_caller_any_conflict_edge :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	w := ecs.scheduler_add(
		s,
		"caller.writer",
		.PHYSICS,
		_sys_serial_caller,
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		// affinity defaults to .CALLER
	)
	r := ecs.scheduler_add(
		s,
		"any.reader",
		.PHYSICS,
		_sys_serial_any,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, _has_edge(s, w, r), "CALLER writer -> ANY reader edge exists")
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(r)], 1)
}

@(private)
g_serial_active: i32
@(private)
g_serial_overlap: i32
@(private)
g_serial_runs: i32

// Widen the critical section so a missing edge would show up as an overlap;
// reading an atomic keeps the loop from being optimised away.
@(private)
_serial_spin :: proc() {
	for _ in 0 ..< 200_000 {_ = sync.atomic_load(&g_serial_active)}
}

@(private)
_serial_enter :: proc() {
	if sync.atomic_add(&g_serial_active, 1) != 0 {sync.atomic_store(&g_serial_overlap, 1)}
}

@(private)
_serial_leave :: proc() {
	sync.atomic_sub(&g_serial_active, 1)
	sync.atomic_add(&g_serial_runs, 1)
}

@(private)
_sys_serial_caller :: proc(w: ^ecs.World, dt: f32) -> bool {
	_serial_enter()
	_serial_spin()
	_serial_leave()
	return true
}

@(private)
_sys_serial_any :: proc(w: ^ecs.World, dt: f32) -> bool {
	_serial_enter()
	_serial_spin()
	_serial_leave()
	return true
}

// Runtime counterpart to the edge test: run a conflicting `.CALLER`/`.ANY` pair
// and assert they never share their critical section. The `.ANY` side is
// registered first so, without the edge, it is submitted to the pool before the
// `.CALLER` side runs inline — which is the race. A debug build keeps `.ANY` on
// the phase thread, so the edge assertion is what has teeth there.
@(test)
test_ecs_scheduler_caller_any_never_overlap :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create(&js)
	defer ecs.scheduler_destroy(s)

	any_sys := ecs.scheduler_add(
		s,
		"any.writer",
		.PHYSICS,
		_sys_serial_any,
		access = ecs.System_Access{writes = {typeid_of(Test_Velocity)}},
		affinity = .ANY,
	)
	caller_sys := ecs.scheduler_add(
		s,
		"caller.reader",
		.PHYSICS,
		_sys_serial_caller,
		access = ecs.System_Access{reads = {typeid_of(Test_Velocity)}},
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, _has_edge(s, any_sys, caller_sys), "ANY writer -> CALLER reader edge")

	sync.atomic_store(&g_serial_active, 0)
	sync.atomic_store(&g_serial_overlap, 0)
	sync.atomic_store(&g_serial_runs, 0)

	testing.expect(t, ecs.scheduler_run(s, .PHYSICS, w, 0.016), "phase succeeds")
	testing.expect_value(t, sync.atomic_load(&g_serial_overlap), i32(0))
	testing.expect_value(t, sync.atomic_load(&g_serial_active), i32(0))
	testing.expect_value(t, sync.atomic_load(&g_serial_runs), i32(2))
}

@(private)
g_stall_runs: i32

@(private)
_sys_stall :: proc(w: ^ecs.World, dt: f32) -> bool {
	sync.atomic_add(&g_stall_runs, 1)
	return true
}

// A graph that can never make progress must fail the phase. Finalize rejects
// cycles, so the stall path is defensive; force it by handing the only system a
// dependency nothing can ever satisfy.
@(test)
test_ecs_scheduler_stall_fails :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	a := ecs.scheduler_add(s, "stall.a", .PHYSICS, _sys_stall)
	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	s.schedule[.PHYSICS].deps[int(a)] = 1

	sync.atomic_store(&g_stall_runs, 0)
	prev := context.logger
	context.logger = log.nil_logger()
	ok := ecs.scheduler_run(s, .PHYSICS, w, 0.016)
	context.logger = prev

	testing.expect(t, !ok, "a stalled graph fails the phase instead of succeeding")
	testing.expect_value(t, sync.atomic_load(&g_stall_runs), i32(0))
}

@(test)
test_ecs_scheduler_readers_share :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	x := ecs.scheduler_add(
		s,
		"x",
		.PHYSICS,
		_sys_a,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	y := ecs.scheduler_add(
		s,
		"y",
		.PHYSICS,
		_sys_b,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, !_has_edge(s, x, y) && !_has_edge(s, y, x), "readers share")
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(x)], 0)
	testing.expect_value(t, s.schedule[.PHYSICS].deps[int(y)], 0)
}

@(test)
test_ecs_scheduler_duplicate_name :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	ecs.scheduler_add(s, "dup", .PHYSICS, _sys_a)
	ecs.scheduler_add(s, "dup", .PHYSICS, _sys_b)

	prev := context.logger
	context.logger = log.nil_logger()
	ok := ecs.scheduler_finalize(s)
	context.logger = prev
	testing.expect(t, !ok, "duplicate names are rejected")
}

@(test)
test_ecs_scheduler_cross_phase_dependency :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	a := ecs.scheduler_add(s, "a", .PHYSICS, _sys_a)
	ecs.scheduler_add(s, "b", .RENDER, _sys_r, after = {a})

	prev := context.logger
	context.logger = log.nil_logger()
	ok := ecs.scheduler_finalize(s)
	context.logger = prev
	testing.expect(t, !ok, "cross-phase dependencies are rejected")
}

@(private)
g_parallel_runs: i32

@(private)
_sys_par_a :: proc(w: ^ecs.World, dt: f32) -> bool {
	sync.atomic_add(&g_parallel_runs, 1)
	return true
}

@(private)
_sys_par_b :: proc(w: ^ecs.World, dt: f32) -> bool {
	sync.atomic_add(&g_parallel_runs, 1)
	return true
}

// Two disjoint ANY systems have no edge between them and both run.
@(test)
test_ecs_scheduler_parallel_nodes_run :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create(&js)
	defer ecs.scheduler_destroy(s)

	a := ecs.scheduler_add(
		s,
		"par.a",
		.PHYSICS,
		_sys_par_a,
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	b := ecs.scheduler_add(
		s,
		"par.b",
		.PHYSICS,
		_sys_par_b,
		access = ecs.System_Access{writes = {typeid_of(Test_Velocity)}},
		affinity = .ANY,
	)
	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect(t, !_has_edge(s, a, b) && !_has_edge(s, b, a), "disjoint nodes independent")

	g_parallel_runs = 0
	testing.expect(t, ecs.scheduler_run(s, .PHYSICS, w, 0.016), "phase succeeds")
	testing.expect_value(t, sync.atomic_load(&g_parallel_runs), i32(2))
}

@(private)
g_graph_order: [dynamic]u8

@(private)
_sys_graph_a :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_graph_order, 'a'); return true}
@(private)
_sys_graph_b :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_graph_order, 'b'); return true}
@(private)
_sys_graph_c :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_graph_order, 'c'); return true}
@(private)
_sys_graph_d :: proc(w: ^ecs.World, dt: f32) -> bool {append(&g_graph_order, 'd'); return true}

// Ready systems start in dependency order and nothing runs before its
// predecessors; the chain a -> {b, c} -> d is deterministic.
@(test)
test_ecs_scheduler_readiness_order :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	a := ecs.scheduler_add(s, "ga", .PHYSICS, _sys_graph_a)
	b := ecs.scheduler_add(
		s,
		"gb",
		.PHYSICS,
		_sys_graph_b,
		after = {a},
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	c := ecs.scheduler_add(
		s,
		"gc",
		.PHYSICS,
		_sys_graph_c,
		after = {a},
		access = ecs.System_Access{writes = {typeid_of(Test_Velocity)}},
		affinity = .ANY,
	)
	ecs.scheduler_add(
		s,
		"gd",
		.PHYSICS,
		_sys_graph_d,
		after = {b, c},
		access = ecs.System_Access{writes = {typeid_of(Test_Probe)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	delete(g_graph_order)
	g_graph_order = {}
	defer delete(g_graph_order)

	testing.expect(t, ecs.scheduler_run(s, .PHYSICS, w, 0.016), "phase succeeds")
	testing.expect_value(t, string(g_graph_order[:]), "abcd")
}

@(test)
test_ecs_deferred_changes :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	a := ecs.world_spawn(w)
	b := ecs.world_spawn(w)
	ecs.world_set(w, a, Test_Position{1, 0, 0})
	ecs.world_set(w, b, Test_Position{2, 0, 0})
	ecs.world_set(w, b, Test_Velocity{3, 0, 0})

	// Queued changes are invisible until the flush, which is what lets a system
	// add/remove components while iterating a view.
	ecs.world_defer_set(w, a, Test_Velocity{4, 0, 0})
	ecs.world_defer_remove(w, b, Test_Velocity)
	testing.expect(t, !ecs.world_has(w, a, Test_Velocity), "deferred set is not applied yet")
	testing.expect(t, ecs.world_has(w, b, Test_Velocity), "deferred remove is not applied yet")

	ecs.world_flush(w)
	testing.expect(t, ecs.world_has(w, a, Test_Velocity))
	testing.expect_value(t, ecs.world_get(w, a, Test_Velocity).x, f32(4))
	testing.expect(t, !ecs.world_has(w, b, Test_Velocity))
	testing.expect(t, ecs.world_validate(w), "world stays consistent")
}

@(test)
test_ecs_reserve_freeze :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	ecs.world_reserve(w, 2)
	a := ecs.world_spawn(w)
	b := ecs.world_spawn(w)
	ecs.world_set(w, a, Test_Position{1, 0, 0})
	ecs.world_freeze(w)

	c := ecs.world_spawn(w)
	testing.expect(t, c == ecs.ENTITY_NONE, "spawning past capacity after freeze fails")
	testing.expect(t, ecs.world_is_alive(w, a) && ecs.world_is_alive(w, b))

	// Within the reserved capacity the columns are already there and usable.
	ecs.world_set(w, b, Test_Position{2, 0, 0})
	testing.expect_value(t, ecs.world_get(w, b, Test_Position).x, f32(2))
	testing.expect(t, ecs.world_validate(w))
}

// After freeze the registries are read-only: requesting a pool for a component
// that was not registered during setup must yield nil rather than allocating a
// pool that could race the other thread. Callers assert on the nil.
@(test)
test_ecs_pool_after_freeze_returns_nil :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	ecs.world_reserve(w, 2)
	_ = ecs.world_pool(w, Test_Position)
	ecs.world_freeze(w)

	prev := context.logger
	context.logger = log.nil_logger()
	missing := ecs.world_pool(w, Test_Velocity)
	context.logger = prev
	testing.expect(t, missing == nil, "new pool after freeze must be nil")

	// A registered pool is still reachable (the frozen path only affects new ones).
	testing.expect(t, ecs.world_pool(w, Test_Position) != nil)
}

@(test)
test_ecs_resource_after_freeze_returns_nil :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	_ = ecs.world_resource(w, Test_Singleton)
	ecs.world_freeze(w)

	prev := context.logger
	context.logger = log.nil_logger()
	missing := ecs.world_resource(w, Test_Position)
	context.logger = prev
	testing.expect(t, missing == nil, "new resource after freeze must be nil")
	testing.expect(t, ecs.world_resource(w, Test_Singleton) != nil, "registered resource stays reachable")
}

@(test)
test_ecs_generation_retires_slot :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)

	a := ecs.world_spawn(w)
	// Simulate a slot that has been recycled to the end of its generation range.
	w.generations[a.index] = ecs.MAX_U32
	stale := ecs.Entity{index = a.index, generation = ecs.MAX_U32}
	ecs.world_despawn(w, stale)
	ecs.world_flush(w)

	testing.expect(t, !ecs.world_is_alive(w, stale))
	testing.expect_value(t, w.generations[a.index], ecs.MAX_U32)
	testing.expect(t, len(w.free) == 0, "wrapped slot must not be recycled")

	b := ecs.world_spawn(w)
	testing.expect(t, b.index != a.index, "retired slot is never reused")
	testing.expect(t, ecs.world_validate(w))
}
