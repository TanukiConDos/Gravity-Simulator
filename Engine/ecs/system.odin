package ecs

import found "../../foundation"

// Systems are plain procedures grouped by phase. The engine runs the PHYSICS
// phase on the physics thread and the RENDER phase on the graphics thread;
// within a phase they execute in registration order (deterministic).
Phase :: enum {
	PHYSICS,
	RENDER,
}

System :: struct {
	name:  string,
	phase: Phase,
	run:   proc(w: ^World, dt: f32),
}

Scheduler :: struct {
	systems: [dynamic]System,
}

scheduler_create :: proc() -> ^Scheduler {
	return new(Scheduler)
}

scheduler_destroy :: proc(s: ^Scheduler) {
	if s == nil {return}
	delete(s.systems)
	free(s)
}

scheduler_add :: proc(
	s: ^Scheduler,
	name: string,
	phase: Phase,
	run: proc(w: ^World, dt: f32),
) {
	append(&s.systems, System{name = name, phase = phase, run = run})
}

scheduler_run :: proc(s: ^Scheduler, phase: Phase, w: ^World, dt: f32) {
	for &sys in s.systems {
		if sys.phase == phase {
			found.profile_scope(sys.name)
			sys.run(w, dt)
		}
	}
}
