package tests

import physics "../Engine/physic"
import ecs "../Engine/ecs"
import foundation "../foundation"
import "core:math/rand"
import "core:slice"
import "core:sync"
import "core:testing"

@(test)
test_octtree_create :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)
	physics.body_spawn(w, {-100, 0, 0}, {0, 0, 0}, 100, 5)

	bodies := ecs.world_pool(w, physics.Body).dense[:]
	tree := physics.octtree_create(physics.body_view(w), 0.5)
	testing.expect(t, tree != nil)
	testing.expect(t, len(tree.nodes) > 0)
	testing.expect(t, len(tree.order) == len(bodies))
	physics.octtree_destroy(tree)
}

@(test)
test_octtree_depth_cap :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)
	physics.body_spawn(w, {-100, 0, 0}, {0, 0, 0}, 100, 5)

	view := physics.body_view(w)
	shallow := physics.octtree_create_ex(view, 0.5, 1, physics.DEFAULT_MIN_HALF_SIZE)
	testing.expect(t, shallow.max_depth == 1)
	testing.expect(t, shallow.max_leaf_depth <= 1)
	testing.expect(t, shallow.node_count > 0)
	physics.octtree_destroy(shallow)

	clamped := physics.octtree_create_ex(view, 0.5, 999, physics.DEFAULT_MIN_HALF_SIZE)
	testing.expect(t, clamped.max_depth == physics.MAX_DEPTH_CAP)
	physics.octtree_destroy(clamped)

	// A non-positive cap means "unspecified", not "depth 1": callers building a
	// zero-value config must still get a usable tree.
	defaulted := physics.octtree_create_ex(view, 0.5, 0, physics.DEFAULT_MIN_HALF_SIZE)
	testing.expect(t, defaulted.max_depth == physics.DEFAULT_MAX_DEPTH)
	physics.octtree_destroy(defaulted)
}

@(test)
test_physic_init_defaults :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)

	// physic_init normalizes the optional octree knobs, so a zero-value Config
	// cannot silently degrade the tree to depth 1.
	physics.physic_init(w, foundation.Config{})
	state := physics.physic_state(w)
	testing.expect_value(t, state.max_depth, physics.DEFAULT_MAX_DEPTH)
	testing.expect(t, state.min_half > 0, "min_half must fall back to a positive default")
}

@(test)
test_octtree_force :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	object_b := physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)

	tree := physics.octtree_create(physics.body_view(w), 0.5)
	physics.octtree_calc_force(tree, object_b.index, 16.0)

	velocity := ecs.world_get(w, object_b, physics.Velocity)
	testing.expect(t, velocity != nil)
	testing.expect(t, velocity.x != 0 || velocity.y != 0 || velocity.z != 0)
	physics.octtree_destroy(tree)
}

@(test)
test_brute_force :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	object_b := physics.body_spawn(w, {100, 0, 0}, {0, 0, 0}, 100, 5)

	config := foundation.Config {
		solver_algorithm    = .BRUTE_FORCE,
		collision_algorithm = .BRUTE_FORCE,
	}
	physics.physic_init(w, config)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	physics.physic_register_systems(s)

	ecs.scheduler_run(s, .PHYSICS, w, 16.0)

	acceleration := ecs.world_get(w, object_b, physics.Acceleration)
	testing.expect(t, acceleration != nil)
	testing.expect(
		t,
		acceleration.x != 0 || acceleration.y != 0 || acceleration.z != 0,
	)
}

@(test)
test_octree_collision :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	a := physics.body_spawn(w, {0, 0, 0}, {0, 0, 0}, 1000, 10)
	b := physics.body_spawn(w, {12, 0, 0}, {0, 0, 0}, 100, 5)

	config := foundation.Config {
		solver_algorithm    = .OCTREE,
		collision_algorithm = .OCTREE,
		theta               = 0.5,
	}
	physics.physic_init(w, config)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	physics.physic_register_systems(s)

	pa := ecs.world_get(w, a, physics.Position)
	pb := ecs.world_get(w, b, physics.Position)
	before := pb.x - pa.x
	// dt = 0 keeps gravity/integration out of the way so only collision moves
	// the bodies: two overlapping spheres (12 < 10 + 5) should separate to 15.
	ecs.scheduler_run(s, .PHYSICS, w, 0.0)
	after := pb.x - pa.x
	testing.expect(t, after > before, "overlapping bodies should separate")
	testing.expectf(t, after > 14.9 && after < 15.1, "expected ~15, got %v", after)
}

@(test)
test_octree_force_collect_equivalence :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	rand.reset_u64(7)
	for _ in 0 ..< 300 {
		physics.body_spawn(
			w,
			{
				rand.float32_range(-100, 100),
				rand.float32_range(-100, 100),
				rand.float32_range(-100, 100),
			},
			{0, 0, 0},
			f64(rand.float32_range(1, 10)),
			rand.float32_range(1, 6),
		)
	}

	view := physics.body_view(w)
	n := len(view.bodies)

	max_radius: f32
	for idx in view.bodies {
		r := f32(view.radius[idx])
		if r > max_radius {max_radius = r}
	}

	tree := physics.octtree_create(view, 0.5)
	defer physics.octtree_destroy(tree)

	// Expected contacts, from the broad-phase query + exact overlap test. This
	// is theta-independent: the opening angle must never hide a contact.
	expected := make([dynamic]physics.Contact, 0, 128)
	defer delete(expected)
	scratch := make([]u32, n)
	defer delete(scratch)
	for a in view.bodies {
		count := 0
		physics.octtree_collect_nearby(
			tree,
			physics.Vec3(view.position[a]),
			f32(view.radius[a]) + max_radius,
			scratch,
			&count,
		)
		for j in 0 ..< count {
			b := scratch[j]
			if b <= a {continue}
			dir := physics.Vec3(view.position[b]) - physics.Vec3(view.position[a])
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			radius_sum := f32(view.radius[a]) + f32(view.radius[b])
			if dist_sq < radius_sum * radius_sum && dist_sq > 0.000001 {
				append(&expected, physics.Contact{a = a, b = b})
			}
		}
	}
	slice.sort_by(expected[:], _contact_less)

	vel := make([]physics.Vec3, n)
	defer delete(vel)
	contacts := make([dynamic]physics.Contact, 0, 128)
	defer delete(contacts)
	mutex: sync.Mutex

	for theta in ([]f32{0.2, 0.5, 0.8, 1.2}) {
		tree.theta = theta

		// Reference: plain gravity only.
		for idx in view.bodies {view.velocity[idx] = physics.Velocity{0, 0, 0}}
		for idx in view.bodies {physics.octtree_calc_force(tree, idx, 1.0)}
		for i in 0 ..< n {vel[i] = physics.Vec3(view.velocity[view.bodies[i]])}

		// Merged gravity + contact collection.
		for idx in view.bodies {view.velocity[idx] = physics.Velocity{0, 0, 0}}
		clear(&contacts)
		for idx in view.bodies {
			physics.octtree_calc_force_and_collect(
				tree,
				idx,
				1.0,
				max_radius,
				&contacts,
				&mutex,
			)
		}
		for i in 0 ..< n {
			got := physics.Vec3(view.velocity[view.bodies[i]])
			testing.expectf(
				t,
				got == vel[i],
				"theta=%v: gravity differs at body %d: %v vs %v",
				theta,
				i,
				got,
				vel[i],
			)
		}

		slice.sort_by(contacts[:], _contact_less)
		testing.expectf(
			t,
			len(contacts) == len(expected),
			"theta=%v: contact count %d != %d",
			theta,
			len(contacts),
			len(expected),
		)
		for i in 0 ..< min(len(contacts), len(expected)) {
			testing.expectf(
				t,
				contacts[i] == expected[i],
				"theta=%v: contact %d differs: %v vs %v",
				theta,
				i,
				contacts[i],
				expected[i],
			)
		}
	}
}

@(private)
_contact_less :: proc(x, y: physics.Contact) -> bool {
	if x.a != y.a {return x.a < y.a}
	return x.b < y.b
}

@(test)
test_body_components :: proc(t: ^testing.T) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	e := physics.body_spawn(w, {1, 2, 3}, {4, 5, 6}, 1000, 10)

	mass := ecs.world_get(w, e, physics.Mass)
	radius := ecs.world_get(w, e, physics.Radius)
	position := ecs.world_get(w, e, physics.Position)
	velocity := ecs.world_get(w, e, physics.Velocity)

	testing.expect(t, mass != nil && f64(mass^) == 1000)
	testing.expect(t, radius != nil && f32(radius^) == 10)
	testing.expect(t, position != nil && position.x == 1 && position.z == 3)
	testing.expect(t, velocity != nil && velocity.y == 5 && velocity.z == 6)
}

@(test)
test_adaptive_decide :: proc(t: ^testing.T) {
	theta := f32(0.5)
	theta_min := f32(0.2)
	theta_max := f32(1.2)

	new_theta, adapted := physics.adaptive_decide(20.0, 10.0, theta, theta_min, theta_max)
	testing.expect(t, adapted, "over budget should adapt")
	testing.expect(t, new_theta > theta, "over budget should raise theta")
	testing.expect(t, new_theta <= theta_max, "theta capped at theta_max")

	new_theta, adapted = physics.adaptive_decide(20.0, 10.0, theta_max, theta_min, theta_max)
	testing.expect(t, !adapted, "over budget with theta pinned should not adapt")

	new_theta, adapted = physics.adaptive_decide(5.0, 10.0, theta, theta_min, theta_max)
	testing.expect(t, adapted, "under budget should adapt")
	testing.expect(t, new_theta < theta, "under budget should lower theta")
	testing.expect(t, new_theta >= theta_min, "theta floored at theta_min")

	new_theta, adapted = physics.adaptive_decide(5.0, 10.0, theta_min, theta_min, theta_max)
	testing.expect(t, !adapted, "under budget with theta at min should not adapt")

	new_theta, adapted = physics.adaptive_decide(10.5, 10.0, theta, theta_min, theta_max)
	testing.expect(t, !adapted, "within deadband should not adapt")
	testing.expect(t, new_theta == theta, "theta unchanged within deadband")
}

@(test)
test_adaptive_tree_stale :: proc(t: ^testing.T) {
	leaf_half := f32(1e8)
	testing.expect(t, !physics.adaptive_tree_stale(f32(1e20), leaf_half, 0), "no rebuild before min updates")
	testing.expect(t, !physics.adaptive_tree_stale(f32(1e20), leaf_half, 1), "no rebuild before min updates (1)")
	testing.expect(t, !physics.adaptive_tree_stale(0, leaf_half, 5), "no rebuild when nothing moved")
	threshold := 0.5 * leaf_half
	threshold_sq := threshold * threshold
	testing.expect(t, physics.adaptive_tree_stale(threshold_sq * 1.5, leaf_half, 5), "rebuild when drift exceeds threshold")
	testing.expect(t, !physics.adaptive_tree_stale(threshold_sq * 0.5, leaf_half, 5), "no rebuild when drift under threshold")
}
