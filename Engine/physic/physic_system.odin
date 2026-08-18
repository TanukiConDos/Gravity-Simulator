package physic

import found "../../foundation"
import "core:math"

PhysicSystem :: struct {
	solver_algo:         found.Algorithm,
	collision_algo:      found.Algorithm,
	theta:               f32,
	rebuild_interval:    f32,
	tree:                ^OctTree,
	tree_accumulator:    f32,
	tree_object_count:   int,
	tree_objects_data:   rawptr,
	collision_scratch:   []^PhysicObject,
}

physic_system_create :: proc(objects: ^[dynamic]PhysicObject, config: ^found.Config) -> PhysicSystem {
	return PhysicSystem{
		solver_algo      = config.solver_algorithm,
		collision_algo   = config.collision_algorithm,
		theta            = config.theta,
		rebuild_interval = config.tree_rebuild_interval,
	}
}

physic_system_destroy :: proc(self: ^PhysicSystem) {
	if self.tree != nil {
		octtree_destroy(self.tree)
		self.tree = nil
	}
	if self.collision_scratch != nil {
		delete(self.collision_scratch)
		self.collision_scratch = nil
	}
}

_ensure_collision_scratch :: proc(self: ^PhysicSystem, count: int) {
	if self.collision_scratch != nil && len(self.collision_scratch) >= count {return}
	if self.collision_scratch != nil {delete(self.collision_scratch)}
	self.collision_scratch = make([]^PhysicObject, count)
}

_ensure_tree :: proc(self: ^PhysicSystem, objects: ^[dynamic]PhysicObject, delta_time: f32) -> ^OctTree {
	objects_slice := objects[:]
	stale :=
		self.tree == nil ||
		self.tree_object_count != len(objects_slice) ||
		self.tree_objects_data != raw_data(objects_slice)

	if !stale && self.rebuild_interval > 0 {
		self.tree_accumulator += delta_time
		if self.tree_accumulator >= self.rebuild_interval {
			stale = true
		}
	}

	if stale || self.rebuild_interval <= 0 {
		if self.tree != nil {
			octtree_rebuild(self.tree, objects_slice, self.theta)
		} else {
			self.tree = octtree_create(objects_slice, self.theta)
		}
		self.tree_object_count = len(objects_slice)
		self.tree_objects_data = raw_data(objects_slice)
		self.tree_accumulator = 0
	}
	return self.tree
}

physic_system_update :: proc(self: ^PhysicSystem, delta_time: f32, objects: ^[dynamic]PhysicObject) {
	if objects == nil || len(objects) == 0 {return}

	seconds := f64(delta_time)

	for &obj in objects {
		obj.acceleration = {0, 0, 0}
	}

	need_tree := self.solver_algo == .OCTREE || self.collision_algo == .OCTREE
	tree: ^OctTree
	if need_tree {
		tree = _ensure_tree(self, objects, delta_time)
	}

	switch self.solver_algo {
	case .BRUTE_FORCE:
		_brute_force_solve(objects[:], seconds)
	case .OCTREE:
		_octree_solve(tree, objects[:], seconds)
	}

	switch self.collision_algo {
	case .BRUTE_FORCE:
		_brute_force_collision(objects[:])
	case .OCTREE:
		_ensure_collision_scratch(self, len(objects))
		_octree_collision(tree, objects[:], self.collision_scratch)
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

_octree_solve :: proc(tree: ^OctTree, objects: []PhysicObject, seconds: f64) {
	if tree == nil {return}
	data := _OctreeSolveData{tree = tree, objects = objects, dt = f32(seconds)}
	found.parallel_for(_octree_solve_worker, &data, len(objects))
}

_OctreeSolveData :: struct {
	tree:    ^OctTree,
	objects: []PhysicObject,
	dt:      f32,
}

_octree_solve_worker :: proc(index: int, data: rawptr) {
	ctx := cast(^_OctreeSolveData)data
	octtree_calc_force(ctx.tree, &ctx.objects[index], ctx.dt)
}

_octree_collision :: proc(tree: ^OctTree, objects: []PhysicObject, nearby: []^PhysicObject) {
	if tree == nil || len(objects) < 2 {return}
	if nearby == nil || len(nearby) < len(objects) {return}

	max_radius: f32
	for obj in objects {
		if obj.radius > max_radius {max_radius = obj.radius}
	}

	for &object_a in objects {
		count := 0
		octtree_collect_nearby(tree, object_a.position, object_a.radius + max_radius, nearby, &count)

		for j in 0 ..< count {
			other := nearby[j]
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
