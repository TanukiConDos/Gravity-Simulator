package physic

import found "../../foundation"
import "core:log"
import "core:math"
import "core:mem"
import "core:sync"
import "core:time"

ADAPTIVE_EMA_ALPHA :: 0.1
ADAPTIVE_WARMUP :: 20
ADAPTIVE_COOLDOWN :: 5
ADAPTIVE_CONFIRM :: 2
ADAPTIVE_DEADBAND :: 0.15
ADAPTIVE_THETA_STEP :: 0.03
ADAPTIVE_HEADROOM :: 0.85
ADAPTIVE_STALE_FACTOR :: 0.5
ADAPTIVE_MIN_REBUILD_UPDATES :: 2

RenderSnapshot :: struct {
	mutex: sync.Mutex,
	data:  [dynamic]Vec3,
}

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
	snapshot:            RenderSnapshot,
	auto_adjust:         bool,
	target_cost_ms:      f32,
	theta_min:           f32,
	theta_max:           f32,
	ema_cost_ms:         f32,
	max_disp_sq:         f32,
	build_positions:     [dynamic]Vec3,
	updates_since_build: int,
	rebuild_count:       int,
	warmup_left:         int,
	cooldown_left:       int,
	above_count:         int,
	below_count:         int,
}

physic_system_create :: proc(
	objects: ^[dynamic]PhysicObject,
	config: ^found.Config,
) -> PhysicSystem {
	s := PhysicSystem {
		solver_algo      = config.solver_algorithm,
		collision_algo   = config.collision_algorithm,
		theta            = config.theta,
		rebuild_interval = config.tree_rebuild_interval,
		auto_adjust      = config.auto_adjust,
		target_cost_ms   = ADAPTIVE_HEADROOM * (1000.0 / max(config.target_tickrate, 1.0)),
		theta_min        = config.theta_min,
		theta_max        = config.theta_max,
		ema_cost_ms      = ADAPTIVE_HEADROOM * (1000.0 / max(config.target_tickrate, 1.0)),
		warmup_left      = ADAPTIVE_WARMUP,
	}
	if s.auto_adjust {
		s.theta = clamp(s.theta, s.theta_min, s.theta_max)
	}
	return s
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
	delete(self.snapshot.data)
	self.snapshot.data = nil
	delete(self.build_positions)
	self.build_positions = nil
}

_ensure_collision_scratch :: proc(self: ^PhysicSystem, count: int) {
	if self.collision_scratch != nil && len(self.collision_scratch) >= count {return}
	if self.collision_scratch != nil {delete(self.collision_scratch)}
	self.collision_scratch = make([]^PhysicObject, count)
}

_ensure_tree :: proc(
	self: ^PhysicSystem,
	objects: ^[dynamic]PhysicObject,
	delta_time: f32,
) -> ^OctTree {
	objects_slice := objects[:]
	stale :=
		self.tree == nil ||
		self.tree_object_count != len(objects_slice) ||
		self.tree_objects_data != raw_data(objects_slice)

	if !stale {
		if self.auto_adjust && self.tree != nil {
			self.tree_accumulator += delta_time
			if self.tree_accumulator >= self.rebuild_interval ||
			   adaptive_tree_stale(
				   self.max_disp_sq,
				   self.tree.typical_half,
				   self.updates_since_build,
			   ) {
				stale = true
			}
		} else if self.rebuild_interval > 0 {
			self.tree_accumulator += delta_time
			if self.tree_accumulator >= self.rebuild_interval {
				stale = true
			}
		}
	}

	if stale || (!self.auto_adjust && self.rebuild_interval <= 0) {
		if self.tree != nil {
			octtree_rebuild(self.tree, objects_slice, self.theta)
		} else {
			self.tree = octtree_create(objects_slice, self.theta)
		}
		self.tree_object_count = len(objects_slice)
		self.tree_objects_data = raw_data(objects_slice)
		self.tree_accumulator = 0
		self.updates_since_build = 0
		self.rebuild_count += 1
		if self.auto_adjust {
			if cap(self.build_positions) < len(objects_slice) {
				resize(&self.build_positions, len(objects_slice))
			}
			for obj, i in objects_slice {
				if i < len(self.build_positions) {
					self.build_positions[i] = obj.position
				}
			}
			self.max_disp_sq = 0
		}
	}
	self.updates_since_build += 1
	return self.tree
}

adaptive_tree_stale :: proc(max_disp_sq, leaf_half: f32, updates_since_build: int) -> bool {
	if updates_since_build < ADAPTIVE_MIN_REBUILD_UPDATES {return false}
	threshold := ADAPTIVE_STALE_FACTOR * leaf_half
	return max_disp_sq > threshold * threshold
}

physic_system_update :: proc(
	self: ^PhysicSystem,
	delta_time: f32,
	objects: ^[dynamic]PhysicObject,
) {
	if objects == nil || len(objects) == 0 {return}

	t0 := time.tick_now()
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
		tree.theta = self.theta
		_octree_solve(tree, objects[:], seconds)
	}

	switch self.collision_algo {
	case .BRUTE_FORCE:
		_brute_force_collision(objects[:])
	case .OCTREE:
		_ensure_collision_scratch(self, len(objects))
		_octree_collision(tree, objects[:], self.collision_scratch)
	}

	for &obj, i in objects {
		obj.position += obj.velocity * f32(seconds)
		if self.auto_adjust && i < len(self.build_positions) {
			drift := obj.position - self.build_positions[i]
			disp_sq := drift.x * drift.x + drift.y * drift.y + drift.z * drift.z
			if disp_sq > self.max_disp_sq {
				self.max_disp_sq = disp_sq
			}
		}
	}

	physic_snapshot_publish(self, objects[:])

	cost_ms := f32(time.duration_milliseconds(time.tick_diff(t0, time.tick_now())))
	_adaptive_controller(self, cost_ms)
}

_adaptive_controller :: proc(self: ^PhysicSystem, cost_ms: f32) {
	if !self.auto_adjust {return}
	if self.solver_algo != .OCTREE && self.collision_algo != .OCTREE {return}

	if self.warmup_left > 0 {
		self.warmup_left -= 1
		return
	}

	self.ema_cost_ms += (cost_ms - self.ema_cost_ms) * ADAPTIVE_EMA_ALPHA

	if self.cooldown_left > 0 {
		self.cooldown_left -= 1
		return
	}

	lo := self.target_cost_ms * (1.0 - ADAPTIVE_DEADBAND)
	hi := self.target_cost_ms * (1.0 + ADAPTIVE_DEADBAND)
	in_band := self.ema_cost_ms >= lo && self.ema_cost_ms <= hi
	if in_band {
		self.above_count = 0
		self.below_count = 0
		return
	}
	if self.ema_cost_ms > hi {
		self.above_count += 1
		self.below_count = 0
	} else {
		self.below_count += 1
		self.above_count = 0
	}
	if self.above_count < ADAPTIVE_CONFIRM && self.below_count < ADAPTIVE_CONFIRM {return}

	use_theta := self.solver_algo == .OCTREE
	theta_min := use_theta ? self.theta_min : self.theta
	theta_max := use_theta ? self.theta_max : self.theta

	new_theta, adapted := adaptive_decide(
		self.ema_cost_ms,
		self.target_cost_ms,
		self.theta,
		theta_min,
		theta_max,
	)
	if !adapted {return}

	self.theta = new_theta
	self.cooldown_left = ADAPTIVE_COOLDOWN
	log.infof(
		"[PHYSIC] adaptive: ema=%.2fms target=%.2fms theta=%.2f rebuilds=%d",
		self.ema_cost_ms,
		self.target_cost_ms,
		self.theta,
		self.rebuild_count,
	)
}

adaptive_decide :: proc(
	ema_cost, target_cost, theta, theta_min, theta_max: f32,
) -> (
	new_theta: f32,
	adapted: bool,
) {
	new_theta = theta
	if target_cost <= 0 {return}

	lo := target_cost * (1.0 - ADAPTIVE_DEADBAND)
	hi := target_cost * (1.0 + ADAPTIVE_DEADBAND)
	if ema_cost >= lo && ema_cost <= hi {return}

	if ema_cost > hi {
		if theta < theta_max {
			new_theta = min(theta + ADAPTIVE_THETA_STEP, theta_max)
			adapted = true
		}
	} else {
		if theta > theta_min {
			new_theta = max(theta - ADAPTIVE_THETA_STEP, theta_min)
			adapted = true
		}
	}
	return
}

physic_snapshot_publish :: proc(self: ^PhysicSystem, objects: []PhysicObject) {
	count := len(objects)
	sync.mutex_lock(&self.snapshot.mutex)
	if cap(self.snapshot.data) < count {
		resize(&self.snapshot.data, count)
	}
	for obj, i in objects {
		self.snapshot.data[i] = obj.position
	}
	sync.mutex_unlock(&self.snapshot.mutex)
}

physic_snapshot_read :: proc(self: ^PhysicSystem, dest: rawptr, max_count: int) -> int {
	sync.mutex_lock(&self.snapshot.mutex)
	n := min(max_count, len(self.snapshot.data))
	if n > 0 && dest != nil {
		mem.copy(dest, raw_data(self.snapshot.data), n * size_of(Vec3))
	}
	sync.mutex_unlock(&self.snapshot.mutex)
	return n
}

_brute_force_solve :: proc(objects: []PhysicObject, seconds: f64) {
	n := len(objects)
	for i in 0 ..< n {
		acc_i := &objects[i].acceleration
		mass_i := objects[i].mass
		for j in i + 1 ..< n {
			dir := objects[j].position - objects[i].position
			dist_sq := f64(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
			if dist_sq < 1e-6 {dist_sq = 1e-6}
			dir_norm := dir / f32(math.sqrt_f64(dist_sq))

			g_over_dist_sq := f32(GRAVITY_CONSTANT / dist_sq)
			acc_i^ += dir_norm * (g_over_dist_sq * f32(objects[j].mass))
			objects[j].acceleration -= dir_norm * (g_over_dist_sq * f32(mass_i))
		}
		objects[i].velocity += acc_i^ * f32(seconds)
	}
}

_brute_force_collision :: proc(objects: []PhysicObject) {
	for &object_a, i in objects {
		for &object_b, j in objects {
			if i >= j {continue}
			dir := object_b.position - object_a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			radius_sum := object_a.radius + object_b.radius
			if dist_sq >= radius_sum * radius_sum || dist_sq <= 0.000001 {continue}
			dist := math.sqrt_f32(dist_sq)
			normal := dir / dist
			overlap := radius_sum - dist
			total_mass := f32(object_a.mass + object_b.mass)
			object_a.position -= normal * (overlap * f32(object_b.mass) / total_mass)
			object_b.position += normal * (overlap * f32(object_a.mass) / total_mass)
		}
	}
}

_octree_solve :: proc(tree: ^OctTree, objects: []PhysicObject, seconds: f64) {
	if tree == nil {return}
	data := _OctreeSolveData {
		tree    = tree,
		objects = objects,
		dt      = f32(seconds),
	}
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
		octtree_collect_nearby(
			tree,
			object_a.position,
			object_a.radius + max_radius,
			nearby,
			&count,
		)

		for j in 0 ..< count {
			other := nearby[j]
			if other == &object_a {continue}
			if uintptr(other) < uintptr(&object_a) {continue}

			dir := other.position - object_a.position
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			radius_sum := object_a.radius + other.radius
			if dist_sq >= radius_sum * radius_sum || dist_sq <= 0.000001 {continue}
			dist := math.sqrt_f32(dist_sq)
			normal := dir / dist
			overlap := radius_sum - dist
			total_mass := f32(object_a.mass + other.mass)
			object_a.position -= normal * (overlap * f32(other.mass) / total_mass)
			other.position += normal * (overlap * f32(object_a.mass) / total_mass)
		}
	}
}
