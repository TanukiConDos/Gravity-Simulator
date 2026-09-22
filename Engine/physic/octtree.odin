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

// The tree stores entity indices and a view over the component columns, so it
// survives pool reallocation (unlike the previous pointer list) and can be
// consumed while entities are being merged away. `order` is the tree's own
// permuted copy of the body list; node ranges index into it.
OctTree :: struct {
	nodes:         []OctTreeNode,
	order:         []u32,
	view:          Bodies,
	theta:         f32,
	arena:         found.Arena,
	typical_half:  f32,
	leaf_obj_hist: [MAX_DEPTH + 1]u32,
}

ChildRange :: struct {
	start: int,
	count: int,
}

octtree_create :: proc(view: Bodies, theta: f32) -> ^OctTree {
	t := new(OctTree)
	t.theta = theta
	t.view = view

	count := len(view.bodies)
	need := octtree_buffer_size(count)
	t.arena = found.arena_create(need)
	t.nodes = _arena_slice(OctTreeNode, &t.arena, count * 8 + 1024)
	t.order = _arena_slice(u32, &t.arena, count)

	_octtree_build(t)
	return t
}

octtree_rebuild :: proc(self: ^OctTree, view: Bodies, theta: f32) {
	if self == nil {return}
	self.theta = theta
	self.view = view

	count := len(view.bodies)
	need := octtree_buffer_size(count)
	if need > len(self.arena.data) {
		found.arena_destroy(&self.arena)
		self.arena = found.arena_create(need)
	}
	found.arena_reset(&self.arena)
	self.nodes = _arena_slice(OctTreeNode, &self.arena, count * 8 + 1024)
	self.order = _arena_slice(u32, &self.arena, count)

	_octtree_build(self)
}

octtree_buffer_size :: proc(object_count: int) -> int {
	return (object_count * 8 + 1024) * size_of(OctTreeNode) + object_count * size_of(u32) + 1024
}

_octtree_build :: proc(t: ^OctTree) {
	copy(t.order, t.view.bodies)

	min := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
	max := Vec3{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
	for idx in t.order {
		p := Vec3(t.view.position[idx])
		if p.x < min.x {min.x = p.x}
		if p.y < min.y {min.y = p.y}
		if p.z < min.z {min.z = p.z}
		if p.x > max.x {max.x = p.x}
		if p.y > max.y {max.y = p.y}
		if p.z > max.z {max.z = p.z}
	}
	center := (min + max) * 0.5
	half := math.max(math.max(max.x - min.x, max.y - min.y), max.z - min.z) * 0.5 + 1.0
	if half <= 0 {half = 1e6}

	t.leaf_obj_hist = {}
	next_node: u32 = 0
	_build_octant(t, 0, len(t.order), center, half, 0, &next_node)

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

	ranges := _partition_bodies(t.order, start, count, center, t.view.position)

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

_partition_bodies :: proc(
	buf: []u32,
	start, count: int,
	center: Vec3,
	position: []Position,
) -> [8]ChildRange {
	end := start + count
	counts: [8]int
	for i in start ..< end {
		counts[_get_octant_index(Vec3(position[buf[i]]), center)] += 1
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
			b := _get_octant_index(Vec3(position[buf[w]]), center)
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
			idx := t.order[i]
			m := f64(t.view.mass[idx])
			p := Vec3(t.view.position[idx])
			node.mass += m
			cm += [3]f64{f64(p.x), f64(p.y), f64(p.z)} * m
		}
	}
	if node.mass > 0 {
		cm /= node.mass
		node.center_mass = {f32(cm[0]), f32(cm[1]), f32(cm[2])}
	}
}

octtree_calc_force :: proc(self: ^OctTree, index: u32, dt: f32) {
	if self == nil || self.nodes == nil {return}
	_calc_force(self, index, self.theta, dt)
}

_calc_force :: proc(t: ^OctTree, index: u32, theta: f32, dt: f32) {
	stack: [4096]u32
	stack_count := 1
	stack[0] = 0
	view := &t.view
	obj_pos := Vec3(view.position[index])
	obj_mass := f64(view.mass[index])

	for stack_count > 0 {
		stack_count -= 1
		node := &t.nodes[stack[stack_count]]

		if node.child_count == 0 {
			for i in node.first_obj ..< node.first_obj + node.obj_count {
				other := t.order[i]
				if other != index {
					_apply_gravity(
						view,
						index,
						obj_pos,
						obj_mass,
						f64(view.mass[other]),
						Vec3(view.position[other]),
						dt,
					)
				}
			}
			continue
		}

		dir := node.center_mass - obj_pos
		dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
		if dist_sq < 1e-10 {dist_sq = 1e-10}
		dist := math.sqrt_f32(dist_sq)

		if (node.half_size * 2) / dist <= theta {
			if node.mass > 0 && dist > 0.001 {
				_apply_gravity(view, index, obj_pos, obj_mass, node.mass, node.center_mass, dt)
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

_apply_gravity :: proc(
	view: ^Bodies,
	index: u32,
	obj_pos: Vec3,
	obj_mass: f64,
	other_mass: f64,
	other_pos: Vec3,
	dt: f32,
) {
	dir := other_pos - obj_pos
	dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
	if dist_sq < 0.001 {dist_sq = 0.001}
	dir_norm := dir / math.sqrt_f32(dist_sq)
	force_mag := f32(GRAVITY_CONSTANT * obj_mass * other_mass / f64(dist_sq))
	acc := dir_norm * (force_mag / f32(obj_mass))
	view.velocity[index] = Velocity(Vec3(view.velocity[index]) + acc * dt)
}

// Appends the entity indices inside `radius` of `pos` into `result`.
octtree_collect_nearby :: proc(
	self: ^OctTree,
	pos: Vec3,
	radius: f32,
	result: []u32,
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
	result: []u32,
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
					result[count^] = t.order[i]
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
