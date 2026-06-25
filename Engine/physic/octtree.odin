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

octtree_destroy :: proc(t: ^OctTree) {
	if t == nil {return}
	_destroy_octant(t.root)
	free(t)
}

_build_octant :: proc(objects: []^PhysicObject, center: Vec3, half: f32) -> ^Octant {
	o := new(Octant)
	o.center = center
	o.half_size = half

	if len(objects) <= 1 {
		o.objects = make([dynamic]^PhysicObject, len(objects))
		copy(o.objects[:], objects)
		octtree_mass_calculation(o)
		return o
	}

	children_objects: [8][dynamic]^PhysicObject
	for ptr in objects {
		idx := _get_octant_index(ptr.position, center)
		append(&children_objects[idx], ptr)
	}

	non_empty := 0
	for g in children_objects {
		if len(g) > 0 {non_empty += 1}
	}

	if non_empty <= 1 {
		o.objects = make([dynamic]^PhysicObject, len(objects))
		copy(o.objects[:], objects)
		octtree_mass_calculation(o)
		for g in children_objects {delete(g)}
		return o
	}

	child_half := half * 0.5
	for i in 0 ..< 8 {
		child_center := center
		child_center.x += (i & 4) != 0 ? child_half : -child_half
		child_center.y += (i & 2) != 0 ? child_half : -child_half
		child_center.z += (i & 1) != 0 ? child_half : -child_half
		o.children[i] = _build_octant(children_objects[i][:], child_center, child_half)
	}
	for g in children_objects {delete(g)}
	octtree_mass_calculation(o)
	return o
}

_get_octant_index :: proc(pos, center: Vec3) -> int {
	return (pos.x >= center.x ? 4 : 0) + (pos.y >= center.y ? 2 : 0) + (pos.z >= center.z ? 1 : 0)
}

octtree_mass_calculation :: proc(o: ^Octant) {
	if o == nil {return}
	o.mass = 0
	o.center_mass = {0, 0, 0}

	has_children := false
	for c in o.children {
		if c != nil {
			has_children = true
			o.mass += c.mass
			o.center_mass += c.center_mass * f32(c.mass)
		}
	}
	if has_children {
		if o.mass > 0 {o.center_mass /= f32(o.mass)}
		return
	}

	for ptr in o.objects {
		o.mass += ptr.mass
		o.center_mass += ptr.position * f32(ptr.mass)
	}
	if o.mass > 0 {o.center_mass /= f32(o.mass)}
}

octtree_calc_force :: proc(t: ^OctTree, obj: ^PhysicObject, dt: f32) {
	if t == nil || t.root == nil {return}
	_calc_force_octant(t.root, obj, t.theta, dt)
}

_calc_force_octant :: proc(o: ^Octant, obj: ^PhysicObject, theta: f32, dt: f32) {
	if o == nil {return}

	has_children := false
	for c in o.children {
		if c != nil {has_children = true; break}
	}

	if !has_children {
		if len(o.objects) == 1 {
			if o.objects[0] != obj {
				_apply_gravity(obj, o.objects[0].mass, o.objects[0].position, dt)
			}
			return
		}
		for ptr in o.objects {
			if ptr != obj {
				_apply_gravity(obj, ptr.mass, ptr.position, dt)
			}
		}
		return
	}

	dir := o.center_mass - obj.position
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	if dist_sq < 1e-10 {dist_sq = 1e-10}
	dist := math.sqrt_f32(dist_sq)

	if (o.half_size * 2) / dist <= theta {
		if o.mass > 0 && dist > 0.001 {
			_apply_gravity(obj, o.mass, o.center_mass, dt)
		}
		return
	}

	for c in o.children {
		_calc_force_octant(c, obj, theta, dt)
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

_collect_nearby_octant :: proc(o: ^Octant, pos: Vec3, radius: f32, result: ^[dynamic]^PhysicObject) {
	if o == nil {return}
	half := o.half_size
	closest_x := math.clamp(pos.x, o.center.x - half, o.center.x + half)
	closest_y := math.clamp(pos.y, o.center.y - half, o.center.y + half)
	closest_z := math.clamp(pos.z, o.center.z - half, o.center.z + half)
	dx := pos.x - closest_x
	dy := pos.y - closest_y
	dz := pos.z - closest_z
	if dx * dx + dy * dy + dz * dz > radius * radius {return}

	has_children := false
	for c in o.children {
		if c != nil {has_children = true; break}
	}

	if !has_children {
		for ptr in o.objects {append(result, ptr)}
	} else {
		for c in o.children {
			_collect_nearby_octant(c, pos, radius, result)
		}
	}
}

octtree_collect_nearby :: proc(t: ^OctTree, pos: Vec3, radius: f32, result: ^[dynamic]^PhysicObject) {
	if t == nil || t.root == nil {return}
	_collect_nearby_octant(t.root, pos, radius, result)
}

_destroy_octant :: proc(o: ^Octant) {
	if o == nil {return}
	for c in o.children {_destroy_octant(c)}
	delete(o.objects)
	free(o)
}
