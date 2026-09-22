package tests

import physics "../Engine/physic"
import ecs "../Engine/ecs"
import foundation "../foundation"
import "core:testing"

@(test)
test_octtree_create :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)
	physics.body_spawn(w, {-100, 0, 0}, {0, 0, 0}, 100, 5)

	bodies := ecs.world_pool(w, physics.Body).dense[:]
	tree := physics.octtree_create(bodies, physics.body_arrays(w), 0.5)
	testing.expect(t, tree != nil)
	testing.expect(t, len(tree.nodes) > 0)
	physics.octtree_destroy(tree)
}

@(test)
test_octtree_force :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	object_b := physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)

	bodies := ecs.world_pool(w, physics.Body).dense[:]
	tree := physics.octtree_create(bodies, physics.body_arrays(w), 0.5)
	physics.octtree_calc_force(tree, object_b.index, 16.0)

	velocity := ecs.world_get(w, object_b, physics.Velocity)
	testing.expect(t, velocity != nil)
	testing.expect(t, velocity.x != 0 || velocity.y != 0 || velocity.z != 0)
	physics.octtree_destroy(tree)
}

@(test)
test_brute_force :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	object_b := physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)

	config := foundation.Config {
		solver_algorithm    = .BRUTE_FORCE,
		collision_algorithm = .BRUTE_FORCE,
	}
	physics.physic_init(w, config)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	physics.physic_register_systems(s)

	ecs.scheduler_run(s, .PHYSICS, w, 16.0)

	acceleration := ecs.world_get(w, object_b, physics.Acceleration)
	testing.expect(t, acceleration != nil)
	testing.expect(
		t,
		acceleration.x != 0 || acceleration.y != 0 || acceleration.z != 0,
	)
}

@(test)
test_body_components :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	e := physics.body_spawn(w, {1, 2, 3}, {4, 5, 6}, 1000, 10)

	mass := ecs.world_get(w, e, physics.Mass)
	radius := ecs.world_get(w, e, physics.Radius)
	position := ecs.world_get(w, e, physics.Position)
	velocity := ecs.world_get(w, e, physics.Velocity)

	testing.expect(t, mass != nil && f64(mass^) == 1000)
	testing.expect(t, radius != nil && f32(radius^) == 10)
	testing.expect(t, position != nil && position.x == 1 && position.z == 3)
	testing.expect(t, velocity != nil && velocity.y == 5 && velocity.z == 6)
}

@(test)
test_adaptive_decide :: proc(t: ^testing.T) {
	theta := f32(0.5)
	theta_min := f32(0.2)
	theta_max := f32(1.2)

	new_theta, adapted := physics.adaptive_decide(20.0, 10.0, theta, theta_min, theta_max)
	testing.expect(t, adapted, "over budget should adapt")
	testing.expect(t, new_theta > theta, "over budget should raise theta")
	testing.expect(t, new_theta <= theta_max, "theta capped at theta_max")

	new_theta, adapted = physics.adaptive_decide(20.0, 10.0, theta_max, theta_min, theta_max)
	testing.expect(t, !adapted, "over budget with theta pinned should not adapt")

	new_theta, adapted = physics.adaptive_decide(5.0, 10.0, theta, theta_min, theta_max)
	testing.expect(t, adapted, "under budget should adapt")
	testing.expect(t, new_theta < theta, "under budget should lower theta")
	testing.expect(t, new_theta >= theta_min, "theta floored at theta_min")

	new_theta, adapted = physics.adaptive_decide(5.0, 10.0, theta_min, theta_min, theta_max)
	testing.expect(t, !adapted, "under budget with theta at min should not adapt")

	new_theta, adapted = physics.adaptive_decide(10.5, 10.0, theta, theta_min, theta_max)
	testing.expect(t, !adapted, "within deadband should not adapt")
	testing.expect(t, new_theta == theta, "theta unchanged within deadband")
}

@(test)
test_adaptive_tree_stale :: proc(t: ^testing.T) {
	leaf_half := f32(1e8)
	testing.expect(t, !physics.adaptive_tree_stale(f32(1e20), leaf_half, 0), "no rebuild before min updates")
	testing.expect(t, !physics.adaptive_tree_stale(f32(1e20), leaf_half, 1), "no rebuild before min updates (1)")
	testing.expect(t, !physics.adaptive_tree_stale(0, leaf_half, 5), "no rebuild when nothing moved")
	threshold := 0.5 * leaf_half
	threshold_sq := threshold * threshold
	testing.expect(t, physics.adaptive_tree_stale(threshold_sq * 1.5, leaf_half, 5), "rebuild when drift exceeds threshold")
	testing.expect(t, !physics.adaptive_tree_stale(threshold_sq * 0.5, leaf_half, 5), "no rebuild when drift under threshold")
}
