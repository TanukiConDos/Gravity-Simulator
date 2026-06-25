package physic

import "core:math"

Vec3 :: [3]f32

GRAVITY_CONSTANT :: 6.67430e-11

Octant :: struct {
	center:      Vec3,
	center_mass: Vec3,
	half_size:   f32,
	mass:        f64,
	objects:     [dynamic]^PhysicObject,
	children:    [8]^Octant,
}

OctTree :: struct {
	root:  ^Octant,
	theta: f32,
}

octtree_create :: proc(objects: []PhysicObject, theta: f32) -> ^OctTree {
	t := new(OctTree)
	t.theta = theta

	ptrs := make([]^PhysicObject, len(objects), context.temp_allocator)
	for &obj, i in objects {
		ptrs[i] = &obj
	}

	min := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
	max := Vec3{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
	for &obj in objects {
		if obj.position.x < min.x {min.x = obj.position.x}
		if obj.position.y < min.y {min.y = obj.position.y}
		if obj.position.z < min.z {min.z = obj.position.z}
		if obj.position.x > max.x {max.x = obj.position.x}
		if obj.position.y > max.y {max.y = obj.position.y}
		if obj.position.z > max.z {max.z = obj.position.z}
	}
	center := (min + max) * 0.5
	half := math.max(math.max(max.x - min.x, max.y - min.y), max.z - min.z) * 0.5 + 1.0
	if half <= 0 {half = 1e6}

	t.root = _build_octant(ptrs, center, half)
	return t
}

octtree_destroy :: proc(self: ^OctTree) {
	if self == nil {return}
	_destroy_octant(self.root)
	free(self)
}

_build_octant :: proc(objects: []^PhysicObject, center: Vec3, half: f32) -> ^Octant {
	octant := new(Octant)
	octant.center = center
	octant.half_size = half

	if len(objects) <= 1 {
		octant.objects = make([dynamic]^PhysicObject, len(objects))
		copy(octant.objects[:], objects)
		octtree_mass_calculation(octant)
		return octant
	}

	children_objects: [8][dynamic]^PhysicObject
	for pointer in objects {
		idx := _get_octant_index(pointer.position, center)
		append(&children_objects[idx], pointer)
	}

	non_empty := 0
	for group in children_objects {
		if len(group) > 0 {non_empty += 1}
	}

	if non_empty <= 1 {
		octant.objects = make([dynamic]^PhysicObject, len(objects))
		copy(octant.objects[:], objects)
		octtree_mass_calculation(octant)
		for group in children_objects {delete(group)}
		return octant
	}

	child_half := half * 0.5
	for i in 0 ..< 8 {
		child_center := center
		child_center.x += (i & 4) != 0 ? child_half : -child_half
		child_center.y += (i & 2) != 0 ? child_half : -child_half
		child_center.z += (i & 1) != 0 ? child_half : -child_half
		octant.children[i] = _build_octant(children_objects[i][:], child_center, child_half)
	}
	for group in children_objects {delete(group)}
	octtree_mass_calculation(octant)
	return octant
}

_get_octant_index :: proc(pos, center: Vec3) -> int {
	return (pos.x >= center.x ? 4 : 0) + (pos.y >= center.y ? 2 : 0) + (pos.z >= center.z ? 1 : 0)
}

octtree_mass_calculation :: proc(octant: ^Octant) {
	if octant == nil {return}
	octant.mass = 0
	octant.center_mass = {0, 0, 0}

	has_children := false
	for child in octant.children {
		if child != nil {
			has_children = true
			octant.mass += child.mass
			octant.center_mass += child.center_mass * f32(child.mass)
		}
	}
	if has_children {
		if octant.mass > 0 {octant.center_mass /= f32(octant.mass)}
		return
	}

	for pointer in octant.objects {
		octant.mass += pointer.mass
		octant.center_mass += pointer.position * f32(pointer.mass)
	}
	if octant.mass > 0 {octant.center_mass /= f32(octant.mass)}
}

octtree_calc_force :: proc(self: ^OctTree, obj: ^PhysicObject, dt: f32) {
	if self == nil || self.root == nil {return}
	_calc_force_octant(self.root, obj, self.theta, dt)
}

_calc_force_octant :: proc(octant: ^Octant, obj: ^PhysicObject, theta: f32, dt: f32) {
	if octant == nil {return}

	has_children := false
	for child in octant.children {
		if child != nil {has_children = true; break}
	}

	if !has_children {
		if len(octant.objects) == 1 {
			if octant.objects[0] != obj {
				_apply_gravity(obj, octant.objects[0].mass, octant.objects[0].position, dt)
			}
			return
		}
		for pointer in octant.objects {
			if pointer != obj {
				_apply_gravity(obj, pointer.mass, pointer.position, dt)
			}
		}
		return
	}

	dir := octant.center_mass - obj.position
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	if dist_sq < 1e-10 {dist_sq = 1e-10}
	dist := math.sqrt_f32(dist_sq)

	if (octant.half_size * 2) / dist <= theta {
		if octant.mass > 0 && dist > 0.001 {
			_apply_gravity(obj, octant.mass, octant.center_mass, dt)
		}
		return
	}

	for child in octant.children {
		_calc_force_octant(child, obj, theta, dt)
	}
}

_apply_gravity :: proc(obj: ^PhysicObject, other_mass: f64, other_pos: Vec3, dt: f32) {
	dir := other_pos - obj.position
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	if dist_sq < 0.001 {dist_sq = 0.001}
	dir_norm := dir / math.sqrt_f32(dist_sq)
	force_mag := f32(GRAVITY_CONSTANT * obj.mass * other_mass / f64(dist_sq))
	acc := dir_norm * (force_mag / f32(obj.mass))
	obj.velocity += acc * dt
}

_collect_nearby_octant :: proc(octant: ^Octant, pos: Vec3, radius: f32, result: ^[dynamic]^PhysicObject) {
	if octant == nil {return}
	half := octant.half_size
	closest_x := math.clamp(pos.x, octant.center.x - half, octant.center.x + half)
	closest_y := math.clamp(pos.y, octant.center.y - half, octant.center.y + half)
	closest_z := math.clamp(pos.z, octant.center.z - half, octant.center.z + half)
	dx := pos.x - closest_x
	dy := pos.y - closest_y
	dz := pos.z - closest_z
	if dx * dx + dy * dy + dz * dz > radius * radius {return}

	has_children := false
	for child in octant.children {
		if child != nil {has_children = true; break}
	}

	if !has_children {
		for pointer in octant.objects {append(result, pointer)}
	} else {
		for child in octant.children {
			_collect_nearby_octant(child, pos, radius, result)
		}
	}
}

octtree_collect_nearby :: proc(self: ^OctTree, pos: Vec3, radius: f32, result: ^[dynamic]^PhysicObject) {
	if self == nil || self.root == nil {return}
	_collect_nearby_octant(self.root, pos, radius, result)
}

_destroy_octant :: proc(octant: ^Octant) {
	if octant == nil {return}
	for child in octant.children {_destroy_octant(child)}
	delete(octant.objects)
	free(octant)
}
