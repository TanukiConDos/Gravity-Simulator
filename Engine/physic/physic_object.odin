package physic

PhysicObject :: struct {
	position:     Vec3,
	velocity:     Vec3,
	acceleration: Vec3,
	mass:         f64,
	radius:       f32,
	selected:     bool,
}

physic_object_make :: proc(position, velocity: Vec3, mass: f64, radius: f32) -> PhysicObject {
	return PhysicObject{position = position, velocity = velocity, mass = mass, radius = radius}
}
