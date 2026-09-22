package tests

import ecs "../Engine/ecs"
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
	ecs.world_flush_despawns(w)
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
	ecs.world_flush_despawns(w)

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
_sys_a :: proc(w: ^ecs.World, dt: f32) {append(&g_scheduler_order, 'a')}
@(private)
_sys_b :: proc(w: ^ecs.World, dt: f32) {append(&g_scheduler_order, 'b')}
@(private)
_sys_r :: proc(w: ^ecs.World, dt: f32) {append(&g_scheduler_order, 'r')}

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

	ecs.scheduler_run(s, .PHYSICS, w, 0.016)
	testing.expect_value(t, string(g_scheduler_order[:]), "ab")

	ecs.scheduler_run(s, .RENDER, w, 0.016)
	testing.expect_value(t, string(g_scheduler_order[:]), "abr")
}
