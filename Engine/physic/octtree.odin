package physic

import found "../../foundation"
import "core:math"
import "core:mem"

Vec3 :: [3]f32

GRAVITY_CONSTANT :: 6.67430e-11

MAX_DEPTH :: 48
MIN_HALF_SIZE :: 1e-4

OctTreeNode :: struct {
	center:      Vec3,
	center_mass: Vec3,
	half_size:   f32,
	mass:        f64,
	first_obj:   u32,
	obj_count:   u32,
	children:    [8]u32,
	child_count: u32,
}

OctTree :: struct {
	nodes:            []OctTreeNode,
	objects:          []^PhysicObject,
	theta:            f32,
	arena:            found.Arena,
	typical_half:     f32,
	leaf_obj_hist:    [MAX_DEPTH + 1]u32,
}

ChildRange :: struct {
	start: int,
	count: int,
}

octtree_create :: proc(objects: []PhysicObject, theta: f32) -> ^OctTree {
	t := new(OctTree)
	t.theta = theta

	need := octtree_buffer_size(len(objects))
	t.arena = found.arena_create(need)
	t.nodes = _arena_slice(OctTreeNode, &t.arena, len(objects) * 8 + 1024)
	t.objects = _arena_slice(^PhysicObject, &t.arena, len(objects))

	_octtree_build(t, objects)
	return t
}

octtree_rebuild :: proc(self: ^OctTree, objects: []PhysicObject, theta: f32) {
	if self == nil {return}
	self.theta = theta

	need := octtree_buffer_size(len(objects))
	if need > len(self.arena.data) {
		found.arena_destroy(&self.arena)
		self.arena = found.arena_create(need)
	}
	found.arena_reset(&self.arena)
	self.nodes = _arena_slice(OctTreeNode, &self.arena, len(objects) * 8 + 1024)
	self.objects = _arena_slice(^PhysicObject, &self.arena, len(objects))

	_octtree_build(self, objects)
}

octtree_buffer_size :: proc(object_count: int) -> int {
	return (object_count * 8 + 1024) * size_of(OctTreeNode) + object_count * size_of(^PhysicObject) + 1024
}

_octtree_build :: proc(t: ^OctTree, objects: []PhysicObject) {
	for &obj, i in objects {
		t.objects[i] = &obj
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

	t.leaf_obj_hist = {}
	next_node: u32 = 0
	_build_octant(t, 0, len(objects), center, half, 0, &next_node)

	total_objects := 0
	for d in 0 ..= MAX_DEPTH {
		total_objects += int(t.leaf_obj_hist[d])
	}
	half_total := total_objects / 2
	cumulative := 0
	median_depth := 0
	for d in 0 ..= MAX_DEPTH {
		cumulative += int(t.leaf_obj_hist[d])
		if cumulative >= half_total {
			median_depth = d
			break
		}
	}
	t.typical_half = half / f32(uint(1) << uint(median_depth))
}

octtree_destroy :: proc(self: ^OctTree) {
	if self == nil {return}
	found.arena_destroy(&self.arena)
	free(self)
}

_build_octant :: proc(
	t: ^OctTree,
	start, count: int,
	center: Vec3,
	half: f32,
	depth: int,
	next_node: ^u32,
) {
	node_idx := next_node^
	next_node^ += 1
	node := &t.nodes[node_idx]
	node.center = center
	node.half_size = half

	if count <= 1 ||
	   depth >= MAX_DEPTH ||
	   half <= MIN_HALF_SIZE ||
	   next_node^ >= u32(len(t.nodes)) {
		node.first_obj = u32(start)
		node.obj_count = u32(count)
		node.child_count = 0
		t.leaf_obj_hist[depth] += u32(count)
		_node_mass_calculation(t, node_idx)
		return
	}

	ranges := _partition_objects(t.objects, start, count, center)

	child_half := half * 0.5
	child_count := 0
	for k in 0 ..< 8 {
		if ranges[k].count > 0 {
			child_center := center
			child_center.x += (k & 4) != 0 ? child_half : -child_half
			child_center.y += (k & 2) != 0 ? child_half : -child_half
			child_center.z += (k & 1) != 0 ? child_half : -child_half
			child_idx := next_node^
			_build_octant(
				t,
				ranges[k].start,
				ranges[k].count,
				child_center,
				child_half,
				depth + 1,
				next_node,
			)
			node.children[child_count] = child_idx
			child_count += 1
		}
	}
	node.child_count = u32(child_count)
	_node_mass_calculation(t, node_idx)
}

_partition_objects :: proc(
	buf: []^PhysicObject,
	start, count: int,
	center: Vec3,
) -> [8]ChildRange {
	end := start + count
	counts: [8]int
	for i in start ..< end {
		counts[_get_octant_index(buf[i].position, center)] += 1
	}

	ranges: [8]ChildRange
	offset := start
	for k in 0 ..< 8 {
		ranges[k] = ChildRange {
			start = offset,
			count = counts[k],
		}
		offset += counts[k]
	}

	write_pos: [8]int
	for k in 0 ..< 8 {
		write_pos[k] = ranges[k].start
	}
	for k in 0 ..< 8 {
		w := write_pos[k]
		w_end := ranges[k].start + ranges[k].count
		for w < w_end {
			b := _get_octant_index(buf[w].position, center)
			if b == k {
				w += 1
				continue
			}
			t := write_pos[b]
			buf[w], buf[t] = buf[t], buf[w]
			write_pos[b] += 1
		}
	}
	return ranges
}

_get_octant_index :: proc(pos, center: Vec3) -> int {
	return (pos.x >= center.x ? 4 : 0) + (pos.y >= center.y ? 2 : 0) + (pos.z >= center.z ? 1 : 0)
}

_node_mass_calculation :: proc(t: ^OctTree, node_idx: u32) {
	node := &t.nodes[node_idx]
	node.mass = 0
	node.center_mass = {0, 0, 0}

	cm: [3]f64
	if node.child_count > 0 {
		for ci in 0 ..< node.child_count {
			child := &t.nodes[node.children[ci]]
			node.mass += child.mass
			cm +=
				[3]f64 {
					f64(child.center_mass.x),
					f64(child.center_mass.y),
					f64(child.center_mass.z),
				} *
				child.mass
		}
	} else {
		for i in node.first_obj ..< node.first_obj + node.obj_count {
			obj := t.objects[i]
			node.mass += obj.mass
			cm += [3]f64{f64(obj.position.x), f64(obj.position.y), f64(obj.position.z)} * obj.mass
		}
	}
	if node.mass > 0 {
		cm /= node.mass
		node.center_mass = {f32(cm[0]), f32(cm[1]), f32(cm[2])}
	}
}

octtree_calc_force :: proc(self: ^OctTree, obj: ^PhysicObject, dt: f32) {
	if self == nil || self.nodes == nil || obj == nil {return}
	_calc_force(self, obj, self.theta, dt)
}

_calc_force :: proc(t: ^OctTree, obj: ^PhysicObject, theta: f32, dt: f32) {
	stack: [4096]u32
	stack_count := 1
	stack[0] = 0

	for stack_count > 0 {
		stack_count -= 1
		node := &t.nodes[stack[stack_count]]

		if node.child_count == 0 {
			for i in node.first_obj ..< node.first_obj + node.obj_count {
				other := t.objects[i]
				if other != obj {
					_apply_gravity(obj, other.mass, other.position, dt)
				}
			}
			continue
		}

		dir := node.center_mass - obj.position
		dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
		if dist_sq < 1e-10 {dist_sq = 1e-10}
		dist := math.sqrt_f32(dist_sq)

		if (node.half_size * 2) / dist <= theta {
			if node.mass > 0 && dist > 0.001 {
				_apply_gravity(obj, node.mass, node.center_mass, dt)
			}
			continue
		}

		for ci in 0 ..< node.child_count {
			if stack_count < len(stack) {
				stack[stack_count] = node.children[ci]
				stack_count += 1
			}
		}
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

octtree_collect_nearby :: proc(
	self: ^OctTree,
	pos: Vec3,
	radius: f32,
	result: []^PhysicObject,
	count: ^int,
) {
	if self == nil || self.nodes == nil {return}
	count^ = 0
	_collect_nearby(self, pos, radius, result, count)
}

_collect_nearby :: proc(
	t: ^OctTree,
	pos: Vec3,
	radius: f32,
	result: []^PhysicObject,
	count: ^int,
) {
	stack: [4096]u32
	stack_count := 1
	stack[0] = 0

	for stack_count > 0 {
		stack_count -= 1
		node := &t.nodes[stack[stack_count]]
		half := node.half_size
		closest_x := math.clamp(pos.x, node.center.x - half, node.center.x + half)
		closest_y := math.clamp(pos.y, node.center.y - half, node.center.y + half)
		closest_z := math.clamp(pos.z, node.center.z - half, node.center.z + half)
		dx := pos.x - closest_x
		dy := pos.y - closest_y
		dz := pos.z - closest_z
		if dx * dx + dy * dy + dz * dz > radius * radius {continue}

		if node.child_count == 0 {
			for i in node.first_obj ..< node.first_obj + node.obj_count {
				if count^ < len(result) {
					result[count^] = t.objects[i]
					count^ += 1
				}
			}
			continue
		}
		for ci in 0 ..< node.child_count {
			if stack_count < len(stack) {
				stack[stack_count] = node.children[ci]
				stack_count += 1
			}
		}
	}
}

_arena_slice :: proc($T: typeid, arena: ^found.Arena, count: int) -> []T {
	if count <= 0 {return nil}
	data := found.arena_alloc(arena, count * size_of(T), align_of(T))
	if data == nil {return nil}
	raw: mem.Raw_Slice
	raw.data = data
	raw.len = count
	return transmute([]T)raw
}
