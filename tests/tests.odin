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
}

@(test)
test_physic_object :: proc(t: ^testing.T) {
	obj := physics.physic_object_make({1, 2, 3}, {4, 5, 6}, 1000, 10)
	testing.expect(t, obj.mass == 1000)
	testing.expect(t, obj.radius == 10)
	testing.expect(t, obj.position.x == 1)
	testing.expect(t, obj.velocity.z == 6)
}
