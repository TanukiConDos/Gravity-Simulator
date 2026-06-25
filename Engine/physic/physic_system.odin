package physic

import found "../../foundation"
import "core:math"

PhysicSystem :: struct {
	solver_algo:    found.Algorithm,
	collision_algo: found.Algorithm,
}

physic_system_create :: proc(objects: ^[dynamic]PhysicObject, config: ^found.Config) -> PhysicSystem {
	return PhysicSystem{
		solver_algo    = config.solver_algorithm,
		collision_algo = config.collision_algorithm,
	}
}

physic_system_destroy :: proc(self: ^PhysicSystem) {}

physic_system_update :: proc(self: ^PhysicSystem, delta_time: f32, objects: ^[dynamic]PhysicObject) {
	if objects == nil || len(objects) == 0 {return}

	time_mult := f64(delta_time)
	seconds := time_mult

	for &obj in objects {
		obj.acceleration = {0, 0, 0}
	}

	switch self.solver_algo {
	case .BRUTE_FORCE:
		_brute_force_solve(objects[:], seconds)
	case .OCTREE:
		_octree_solve(objects[:], delta_time)
	}

	switch self.collision_algo {
	case .BRUTE_FORCE:
		_brute_force_collision(objects[:])
	case .OCTREE:
		_octree_collision(objects[:])
	}

	for &obj in objects {
		obj.position += obj.velocity * f32(seconds)
	}
}

_brute_force_solve :: proc(objects: []PhysicObject, seconds: f64) {
	for &a, i in objects {
		for b, j in objects {
			if i == j {continue}
			dir := b.position - a.position
			dist_sq := f64(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
			if dist_sq < 1e-6 {dist_sq = 1e-6}
			dir_norm := dir / f32(math.sqrt_f64(dist_sq))
			force := f32(GRAVITY_CONSTANT * a.mass * b.mass / dist_sq)
			a.acceleration += dir_norm * (force / f32(a.mass))
		}
		a.velocity += a.acceleration * f32(seconds)
	}
}

_brute_force_collision :: proc(objects: []PhysicObject) {
	for &object_a, i in objects {
		for &object_b, j in objects {
			if i >= j {continue}
			dir := object_b.position - object_a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			dist := math.sqrt_f32(dist_sq)
			if dist < object_a.radius + object_b.radius && dist > 0.001 {
				normal := dir / dist
				overlap := object_a.radius + object_b.radius - dist
				total_mass := f32(object_a.mass + object_b.mass)
				object_a.position -= normal * (overlap * f32(object_b.mass) / total_mass)
				object_b.position += normal * (overlap * f32(object_a.mass) / total_mass)
			}
		}
	}
}

_octree_solve :: proc(objects: []PhysicObject, delta_time: f32) {
	tree := octtree_create(objects, 0.5)
	if tree != nil && tree.root != nil {
		for &obj in objects {
			octtree_calc_force(tree, &obj, delta_time)
		}
	}
	octtree_destroy(tree)
}

_octree_collision :: proc(objects: []PhysicObject) {
	if len(objects) < 2 {return}

	tree := octtree_create(objects, 0.5)
	defer octtree_destroy(tree)
	if tree == nil || tree.root == nil {return}

	max_radius: f32
	for obj in objects {
		if obj.radius > max_radius {max_radius = obj.radius}
	}

	nearby := make([dynamic]^PhysicObject, context.temp_allocator)

	for &object_a, i in objects {
		clear(&nearby)
		octtree_collect_nearby(tree, object_a.position, object_a.radius + max_radius, &nearby)

		for other in nearby {
			if other == &object_a {continue}
			if uintptr(other) < uintptr(&object_a) {continue}

			dir := other.position - object_a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			dist := math.sqrt_f32(dist_sq)
			if dist < object_a.radius + other.radius && dist > 0.001 {
				normal := dir / dist
				overlap := object_a.radius + other.radius - dist
				total_mass := f32(object_a.mass + other.mass)
				object_a.position -= normal * (overlap * f32(other.mass) / total_mass)
				other.position += normal * (overlap * f32(object_a.mass) / total_mass)
			}
		}
	}
}
