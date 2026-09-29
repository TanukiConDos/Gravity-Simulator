package physic

import ecs "../ecs"

// Physics components. They are distinct types so each gets its own pool, and
// because pools are indexed by entity index the position/velocity/acceleration/
// mass/radius columns of a body stay aligned without any lookup. `Body` is a tag
// marking the entities the simulation iterates.
Position     :: distinct Vec3
Velocity     :: distinct Vec3
Acceleration :: distinct Vec3
Mass         :: distinct f64
Radius       :: distinct f32
Selected     :: distinct bool

Body :: struct {
	_pad: u8,
}

// One non-owning view over the body columns plus the live body list. Every field
// is a borrowed slice header over a pool; no data is copied. Consumers read only
// the columns they need.
Bodies :: struct {
	bodies:   []u32,
	position: []Position,
	velocity: []Velocity,
	mass:     []Mass,
	radius:   []Radius,
	selected: []Selected,
}

body_spawn :: proc(
	w: ^ecs.World,
	position: Vec3,
	velocity: Vec3,
	mass: f64,
	radius: f32,
) -> ecs.Entity {
	e := ecs.world_spawn(w)
	ecs.world_set(w, e, Body{})
	ecs.world_set(w, e, Position(position))
	ecs.world_set(w, e, Velocity(velocity))
	ecs.world_set(w, e, Acceleration(Vec3{0, 0, 0}))
	ecs.world_set(w, e, Mass(mass))
	ecs.world_set(w, e, Radius(radius))
	ecs.world_set(w, e, Selected(false))
	return e
}

body_count :: proc(w: ^ecs.World) -> int {
	bodies := ecs.world_pool(w, Body)
	assert(bodies != nil, "body_count: Body pool missing (world frozen before setup?)")
	return len(bodies.dense)
}

body_view :: proc(w: ^ecs.World) -> Bodies {
	body_pool := ecs.world_pool(w, Body)
	position := ecs.world_pool(w, Position)
	velocity := ecs.world_pool(w, Velocity)
	mass := ecs.world_pool(w, Mass)
	radius := ecs.world_pool(w, Radius)
	selected := ecs.world_pool(w, Selected)
	assert(
		body_pool != nil &&
		position != nil &&
		velocity != nil &&
		mass != nil &&
		radius != nil &&
		selected != nil,
		"body_view: body pools missing (world frozen before setup?)",
	)
	when ODIN_DEBUG {
		_body_view_validate(w, body_pool.dense[:])
	}
	return Bodies {
		bodies   = body_pool.dense[:],
		position = position.data[:],
		velocity = velocity.data[:],
		mass     = mass.data[:],
		radius   = radius.data[:],
		selected = selected.data[:],
	}
}

// A body view indexes every column by entity index, so the columns only line up
// if each body carries all of them. `body_spawn` is the only constructor and
// adds them together, but a stray `world_remove` would silently break the
// invariant; check it in debug instead of reading garbage in release.
@(private)
_body_view_validate :: proc(w: ^ecs.World, bodies: []u32) {
	position := ecs.world_pool(w, Position)
	velocity := ecs.world_pool(w, Velocity)
	acceleration := ecs.world_pool(w, Acceleration)
	mass := ecs.world_pool(w, Mass)
	radius := ecs.world_pool(w, Radius)
	selected := ecs.world_pool(w, Selected)
	for idx in bodies {
		assert(ecs.pool_has(position, idx), "body is missing Position")
		assert(ecs.pool_has(velocity, idx), "body is missing Velocity")
		assert(ecs.pool_has(acceleration, idx), "body is missing Acceleration")
		assert(ecs.pool_has(mass, idx), "body is missing Mass")
		assert(ecs.pool_has(radius, idx), "body is missing Radius")
		assert(ecs.pool_has(selected, idx), "body is missing Selected")
	}
}
