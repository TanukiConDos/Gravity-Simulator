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

// Two `.ANY` systems with disjoint access share a wave; a dependency or an
// access conflict splits it, and `.CALLER` systems are barriers.
@(test)
test_ecs_scheduler_waves :: proc(t: ^testing.T) {
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
		after = {b, c},
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	waves := s.schedule[.PHYSICS].waves
	testing.expect_value(t, len(waves), 3)
	testing.expect_value(t, len(waves[0].systems), 1)
	testing.expect_value(t, waves[0].systems[0], a)
	testing.expect(t, !waves[0].parallel, "a CALLER system runs alone")

	testing.expect_value(t, len(waves[1].systems), 2)
	testing.expect(t, waves[1].parallel, "disjoint ANY systems share a wave")
	testing.expect_value(t, waves[1].systems[0], b)
	testing.expect_value(t, waves[1].systems[1], c)

	testing.expect_value(t, len(waves[2].systems), 1)
	testing.expect_value(t, waves[2].systems[0], d)
	testing.expect(t, !waves[2].parallel, "a dependency prevents sharing")
}

@(test)
test_ecs_scheduler_access_conflict_serializes :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	ecs.scheduler_add(
		s,
		"x",
		.PHYSICS,
		_sys_a,
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	ecs.scheduler_add(
		s,
		"y",
		.PHYSICS,
		_sys_b,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	waves := s.schedule[.PHYSICS].waves
	testing.expect_value(t, len(waves), 2)
	testing.expect(t, !waves[0].parallel && !waves[1].parallel, "writer vs reader serialises")
}

@(test)
test_ecs_scheduler_readers_share :: proc(t: ^testing.T) {
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)

	ecs.scheduler_add(
		s,
		"x",
		.PHYSICS,
		_sys_a,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	ecs.scheduler_add(
		s,
		"y",
		.PHYSICS,
		_sys_b,
		access = ecs.System_Access{reads = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)

	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	waves := s.schedule[.PHYSICS].waves
	testing.expect_value(t, len(waves), 1)
	testing.expect(t, waves[0].parallel, "two readers share a wave")
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

// The two disjoint ANY systems resolve to one wave; the pool path runs in
// release and the serial fallback in debug, but both must execute.
@(test)
test_ecs_scheduler_parallel_wave_runs :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	w := ecs.world_create()
	defer ecs.world_destroy(w)
	s := ecs.scheduler_create(&js)
	defer ecs.scheduler_destroy(s)

	ecs.scheduler_add(
		s,
		"par.a",
		.PHYSICS,
		_sys_par_a,
		access = ecs.System_Access{writes = {typeid_of(Test_Position)}},
		affinity = .ANY,
	)
	ecs.scheduler_add(
		s,
		"par.b",
		.PHYSICS,
		_sys_par_b,
		access = ecs.System_Access{writes = {typeid_of(Test_Velocity)}},
		affinity = .ANY,
	)
	testing.expect(t, ecs.scheduler_finalize(s), "schedule resolves")
	testing.expect_value(t, len(s.schedule[.PHYSICS].waves), 1)
	testing.expect(t, s.schedule[.PHYSICS].waves[0].parallel)

	g_parallel_runs = 0
	testing.expect(t, ecs.scheduler_run(s, .PHYSICS, w, 0.016), "wave succeeds")
	testing.expect_value(t, sync.atomic_load(&g_parallel_runs), i32(2))
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
