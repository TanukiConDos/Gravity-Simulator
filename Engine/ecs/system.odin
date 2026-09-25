package ecs

import found "../../foundation"

// Systems are plain procedures grouped by phase. The engine runs the PHYSICS
// phase on the physics thread and the RENDER phase on the graphics thread;
// within a phase they execute in registration order (deterministic). A system
// returns false to abort the phase (a fatal error); the scheduler then stops and
// reports it to its caller.
Phase :: enum {
	PHYSICS,
	RENDER,
}

System :: struct {
	name:  string,
	phase: Phase,
	run:   proc(w: ^World, dt: f32) -> bool,
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
	run: proc(w: ^World, dt: f32) -> bool,
) {
	append(&s.systems, System{name = name, phase = phase, run = run})
}

// Runs every system of `phase` in registration order and returns false as soon
// as one fails. Deferred structural changes are not applied here: the phase may
// run on a non-owning thread, so the world's owner flushes explicitly.
scheduler_run :: proc(s: ^Scheduler, phase: Phase, w: ^World, dt: f32) -> bool {
	for &sys in s.systems {
		if sys.phase == phase {
			found.profile_scope(sys.name)
			if !sys.run(w, dt) {return false}
		}
	}
	return true
}
