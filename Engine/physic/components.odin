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
	return len(ecs.world_pool(w, Body).dense)
}

body_view :: proc(w: ^ecs.World) -> Bodies {
	bodies := ecs.world_pool(w, Body).dense[:]
	when ODIN_DEBUG {
		_body_view_validate(w, bodies)
	}
	return Bodies {
		bodies   = bodies,
		position = ecs.world_pool(w, Position).data[:],
		velocity = ecs.world_pool(w, Velocity).data[:],
		mass     = ecs.world_pool(w, Mass).data[:],
		radius   = ecs.world_pool(w, Radius).data[:],
		selected = ecs.world_pool(w, Selected).data[:],
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
