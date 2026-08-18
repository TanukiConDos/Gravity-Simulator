package tests

import physics "../Engine/physic"
import foundation "../foundation"
import "core:testing"

@(test)
test_octtree_create :: proc(t: ^testing.T) {
	objects := [?]physics.PhysicObject{
		physics.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10),
		physics.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5),
		physics.physic_object_make({-100, 0, 0}, {0, 0, 0}, 100, 5),
	}
	tree := physics.octtree_create(objects[:], 0.5)
	testing.expect(t, tree != nil)
	testing.expect(t, len(tree.nodes) > 0)
	physics.octtree_destroy(tree)
}

@(test)
test_octtree_force :: proc(t: ^testing.T) {
	object_a := physics.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10)
	object_b := physics.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5)
	objects := [?]physics.PhysicObject{object_a, object_b}
	tree := physics.octtree_create(objects[:], 0.5)
	physics.octtree_calc_force(tree, &objects[1], 16.0)
	testing.expect(t, objects[1].velocity.x != 0 || objects[1].velocity.y != 0 || objects[1].velocity.z != 0)
	physics.octtree_destroy(tree)
}

@(test)
test_brute_force :: proc(t: ^testing.T) {
	initial_objects := [?]physics.PhysicObject{
		physics.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10),
		physics.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5),
	}
	objects := make([dynamic]physics.PhysicObject, 2); defer delete(objects)
	objects[0] = initial_objects[0]; objects[1] = initial_objects[1]
	system := physics.physic_system_create(&objects, foundation.config_get())
	physics.physic_system_update(&system, 16.0, &objects)
	has_accel := objects[1].acceleration.x != 0 || objects[1].acceleration.y != 0 || objects[1].acceleration.z != 0
	testing.expect(t, has_accel)
	physics.physic_system_destroy(&system)
}

@(test)
test_physic_object :: proc(t: ^testing.T) {
	obj := physics.physic_object_make({1, 2, 3}, {4, 5, 6}, 1000, 10)
	testing.expect(t, obj.mass == 1000)
	testing.expect(t, obj.radius == 10)
	testing.expect(t, obj.position.x == 1)
	testing.expect(t, obj.velocity.z == 6)
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
