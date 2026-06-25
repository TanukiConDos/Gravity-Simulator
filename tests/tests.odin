package tests

import phys "../engine/physic"
import found "../foundation"
import "core:testing"

@(test)
test_octtree_create :: proc(t: ^testing.T) {
	objects := [?]phys.PhysicObject{
		phys.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10),
		phys.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5),
		phys.physic_object_make({-100, 0, 0}, {0, 0, 0}, 100, 5),
	}
	tree := phys.octtree_create(objects[:], 0.5)
	testing.expect(t, tree != nil)
	testing.expect(t, tree.root != nil)
	phys.octtree_destroy(tree)
}

@(test)
test_octtree_force :: proc(t: ^testing.T) {
	a := phys.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10)
	b := phys.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5)
	objects := [?]phys.PhysicObject{a, b}
	tree := phys.octtree_create(objects[:], 0.5)
	phys.octtree_calc_force(tree, &objects[1], 16.0)
	testing.expect(t, objects[1].velocity.x != 0 || objects[1].velocity.y != 0 || objects[1].velocity.z != 0)
	phys.octtree_destroy(tree)
}

@(test)
test_brute_force :: proc(t: ^testing.T) {
	objects := [?]phys.PhysicObject{
		phys.physic_object_make({0, 0, 0}, {0, 0, 0}, 1000, 10),
		phys.physic_object_make({100, 0, 0}, {0, 0, 0}, 100, 5),
	}
	objs := make([dynamic]phys.PhysicObject, 2); defer delete(objs)
	objs[0] = objects[0]; objs[1] = objects[1]
	sys := phys.physic_system_create(&objs, found.config_get())
	phys.physic_system_update(&sys, 16.0, &objs)
	has_accel := objs[1].acceleration.x != 0 || objs[1].acceleration.y != 0 || objs[1].acceleration.z != 0
	testing.expect(t, has_accel)
}

@(test)
test_physic_object :: proc(t: ^testing.T) {
	obj := phys.physic_object_make({1, 2, 3}, {4, 5, 6}, 1000, 10)
	testing.expect(t, obj.mass == 1000)
	testing.expect(t, obj.radius == 10)
	testing.expect(t, obj.position.x == 1)
	testing.expect(t, obj.velocity.z == 6)
}
