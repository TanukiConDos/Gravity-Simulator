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

physic_system_destroy :: proc(ps: ^PhysicSystem) {}

physic_system_update :: proc(ps: ^PhysicSystem, delta_time: f32, objects: ^[dynamic]PhysicObject) {
	if objects == nil || len(objects) == 0 {return}

	time_mult := f64(delta_time)
	seconds := time_mult

	for &obj in objects {
		obj.acceleration = {0, 0, 0}
	}

	switch ps.solver_algo {
	case .BRUTE_FORCE:
		_brute_force_solve(objects[:], seconds)
	case .OCTREE:
		_octree_solve(objects[:], delta_time)
	}

	switch ps.collision_algo {
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
	for &a, i in objects {
		for &b, j in objects {
			if i >= j {continue}
			dir := b.position - a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			dist := math.sqrt_f32(dist_sq)
			if dist < a.radius + b.radius && dist > 0.001 {
				normal := dir / dist
				overlap := a.radius + b.radius - dist
				total_mass := f32(a.mass + b.mass)
				a.position -= normal * (overlap * f32(b.mass) / total_mass)
				b.position += normal * (overlap * f32(a.mass) / total_mass)
			}
		}
	}
}

_octree_solve :: proc(objects: []PhysicObject, delta_time: f32) {
	t := octtree_create(objects, 0.5)
	if t != nil && t.root != nil {
		for &obj in objects {
			octtree_calc_force(t, &obj, delta_time)
		}
	}
	octtree_destroy(t)
}

_octree_collision :: proc(objects: []PhysicObject) {
	if len(objects) < 2 {return}

	t := octtree_create(objects, 0.5)
	defer octtree_destroy(t)
	if t == nil || t.root == nil {return}

	max_radius: f32
	for obj in objects {
		if obj.radius > max_radius {max_radius = obj.radius}
	}

	nearby := make([dynamic]^PhysicObject, context.temp_allocator)

	for &a, i in objects {
		clear(&nearby)
		octtree_collect_nearby(t, a.position, a.radius + max_radius, &nearby)

		for other in nearby {
			if other == &a {continue}
			if uintptr(other) < uintptr(&a) {continue}

			dir := other.position - a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			dist := math.sqrt_f32(dist_sq)
			if dist < a.radius + other.radius && dist > 0.001 {
				normal := dir / dist
				overlap := a.radius + other.radius - dist
				total_mass := f32(a.mass + other.mass)
				a.position -= normal * (overlap * f32(other.mass) / total_mass)
				other.position += normal * (overlap * f32(a.mass) / total_mass)
			}
		}
	}
}
