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
	return Bodies {
		bodies   = ecs.world_pool(w, Body).dense[:],
		position = ecs.world_pool(w, Position).data[:],
		velocity = ecs.world_pool(w, Velocity).data[:],
		mass     = ecs.world_pool(w, Mass).data[:],
		radius   = ecs.world_pool(w, Radius).data[:],
		selected = ecs.world_pool(w, Selected).data[:],
	}
}
