package ecs

import found "../../foundation"
import "core:log"

// Systems are plain procedures grouped by phase. The engine runs the PHYSICS
// phase on the physics thread and the RENDER phase on the graphics thread. A
// system returns false to abort the phase (a fatal error); the scheduler then
// stops and reports it to its caller.
//
// Within a phase the execution order comes from `scheduler_finalize`, not from
// registration order: each system may declare which systems it must run after,
// and the scheduler also serialises systems that touch the same components. The
// resolved schedule is cached as a list of waves; a wave with more than one
// system is a set of mutually independent systems.
Phase :: enum {
	PHYSICS,
	RENDER,
}

// Stable identity of a registered system, returned by `scheduler_add`. Handles
// only exist for already-registered systems, so a dependency edge always points
// backwards and the graph cannot contain a cycle by construction.
System_Handle :: distinct u32

INVALID_SYSTEM :: System_Handle(0xFFFFFFFF)

// Whether a system may leave the phase thread and share a wave with others.
// `.CALLER` (default) runs alone on the phase thread: it is the safe choice for
// systems that mutate structure, call `parallel_for` or touch the renderer.
Affinity :: enum {
	CALLER,
	ANY,
}

// Declared data access, used only to serialise `.ANY` systems that would
// otherwise share a wave. A system that touches a component must list it here;
// callers are trusted to keep the declaration truthful.
System_Access :: struct {
	reads:  []typeid,
	writes: []typeid,
}

System :: struct {
	name:     string,
	phase:    Phase,
	run:      proc(w: ^World, dt: f32) -> bool,
	after:    [dynamic]System_Handle,
	access:   System_Access,
	affinity: Affinity,
}

// A group of systems that can run together: `parallel` is true only when the
// wave holds more than one `.ANY` system with no dependency or access conflict.
Wave :: struct {
	systems:  [dynamic]System_Handle,
	parallel: bool,
}

// Per-phase schedule resolved by `scheduler_finalize`. Public so callers and
// tests can inspect the order and wave grouping.
Phase_Schedule :: struct {
	waves: [dynamic]Wave,
}

Scheduler :: struct {
	systems:   [dynamic]System,
	finalized: bool,
	schedule:  [Phase]Phase_Schedule,
}

scheduler_create :: proc() -> ^Scheduler {
	return new(Scheduler)
}

scheduler_destroy :: proc(s: ^Scheduler) {
	if s == nil {return}
	for &sys in s.systems {delete(sys.after)}
	delete(s.systems)
	for &sch in s.schedule {
		for &wave in sch.waves {delete(wave.systems)}
		delete(sch.waves)
	}
	free(s)
}

scheduler_add :: proc(
	s: ^Scheduler,
	name: string,
	phase: Phase,
	run: proc(w: ^World, dt: f32) -> bool,
	after: []System_Handle = nil,
	access: System_Access = {},
	affinity: Affinity = .CALLER,
) -> System_Handle {
	if s.finalized {
		assert(false, "scheduler_add: cannot add a system after scheduler_finalize")
		log.errorf("[ECS] scheduler_add(%q) after finalize is ignored", name)
		return INVALID_SYSTEM
	}
	sys := System {
		name     = name,
		phase    = phase,
		run      = run,
		access   = access,
		affinity = affinity,
	}
	for a in after {append(&sys.after, a)}
	h := System_Handle(len(s.systems))
	append(&s.systems, sys)
	return h
}

// Resolves the execution order and waves for every phase. Validates names and
// handles; returns false (and logs) on a duplicate name, an unknown handle or a
// handle from another phase. Idempotent.
scheduler_finalize :: proc(s: ^Scheduler) -> bool {
	if s.finalized {return true}
	ok := true
	for i in 0 ..< len(s.systems) {
		for j in i + 1 ..< len(s.systems) {
			if s.systems[i].name == s.systems[j].name {
				log.errorf("[ECS] scheduler: duplicate system name %q", s.systems[i].name)
				ok = false
			}
		}
	}
	for i in 0 ..< len(s.systems) {
		sys := &s.systems[i]
		for a in sys.after {
			if int(a) >= len(s.systems) {
				log.errorf(
					"[ECS] scheduler: %q depends on unknown handle %d",
					sys.name,
					a,
				)
				ok = false
			} else if s.systems[a].phase != sys.phase {
				log.errorf(
					"[ECS] scheduler: %q depends on %q from another phase",
					sys.name,
					s.systems[a].name,
				)
				ok = false
			}
		}
		if sys.affinity == .ANY && len(sys.access.reads) == 0 && len(sys.access.writes) == 0 {
			log.warnf(
				"[ECS] scheduler: .ANY system %q declares no access and may race",
				sys.name,
			)
		}
	}
	if !ok {return false}

	for phase in ([]Phase{.PHYSICS, .RENDER}) {
		if !_build_schedule(s, phase) {ok = false}
	}
	s.finalized = ok
	if ok {_log_schedule(s)}
	return ok
}

// Topologically orders one phase by explicit dependencies (deterministic: ties
// break by registration order) and groups the result into waves. Consecutive
// `.ANY` systems join a wave while they depend on nothing inside it and conflict
// with none of its members; `.CALLER` systems are barriers that run alone.
@(private)
_build_schedule :: proc(s: ^Scheduler, phase: Phase) -> bool {
	indices := make([dynamic]int, 0, 8)
	defer delete(indices)
	for i in 0 ..< len(s.systems) {
		if s.systems[i].phase == phase {append(&indices, i)}
	}
	if len(indices) == 0 {return true}

	n := len(s.systems)
	adj := make([dynamic][dynamic]int, n)
	defer {
		for &a in adj {delete(a)}
		delete(adj)
	}
	indeg := make([]int, n)
	defer delete(indeg)
	for i in 0 ..< n {adj[i] = make([dynamic]int, 0, 4)}

	for i in indices {
		for a in s.systems[i].after {
			if int(a) >= n {continue}
			append(&adj[int(a)], i)
			indeg[i] += 1
		}
	}

	order := make([dynamic]int, 0, len(indices))
	defer delete(order)
	done := make([]bool, n)
	defer delete(done)
	for len(order) < len(indices) {
		pick := -1
		for i in indices {
			if !done[i] && indeg[i] == 0 {
				pick = i
				break
			}
		}
		if pick < 0 {
			log.errorf("[ECS] scheduler: dependency cycle in phase %v", phase)
			return false
		}
		done[pick] = true
		append(&order, pick)
		for j in adj[pick] {if !done[j] {indeg[j] -= 1}}
	}

	waves := &s.schedule[phase].waves
	current := make([dynamic]int, 0, 4)
	defer delete(current)
	for h in order {
		sys := &s.systems[h]
		if sys.affinity != .ANY {
			_wave_flush(waves, &current)
			append(waves, _singleton_wave(h))
			continue
		}
		can_join := true
		for c in current {
			if _depends_on(sys, System_Handle(c)) || _conflicts(sys, &s.systems[c]) {
				can_join = false
				break
			}
		}
		if !can_join {_wave_flush(waves, &current)}
		append(&current, h)
	}
	_wave_flush(waves, &current)
	return true
}

@(private)
_singleton_wave :: proc(h: int) -> Wave {
	w := Wave{}
	append(&w.systems, System_Handle(h))
	return w
}

@(private)
_wave_flush :: proc(waves: ^[dynamic]Wave, current: ^[dynamic]int) {
	if len(current^) == 0 {return}
	w := Wave{parallel = len(current^) > 1}
	for h in current^ {append(&w.systems, System_Handle(h))}
	append(waves, w)
	clear(current)
}

@(private)
_depends_on :: proc(sys: ^System, h: System_Handle) -> bool {
	for a in sys.after {
		if a == h {return true}
	}
	return false
}

@(private)
_conflicts :: proc(a, b: ^System) -> bool {
	for t in a.access.writes {
		for u in b.access.writes {if t == u {return true}}
		for u in b.access.reads {if t == u {return true}}
	}
	for t in a.access.reads {
		for u in b.access.writes {if t == u {return true}}
	}
	return false
}

@(private)
_log_schedule :: proc(s: ^Scheduler) {
	for phase in ([]Phase{.PHYSICS, .RENDER}) {
		sch := &s.schedule[phase]
		if len(sch.waves) == 0 {continue}
		log.debugf("[ECS] schedule %v:", phase)
		for &wave in sch.waves {
			for h in wave.systems {
				log.debugf("  %v %q", wave.parallel ? "||" : "->", s.systems[h].name)
			}
		}
	}
}

// Runs every wave of `phase` in order and returns false as soon as a system
// fails (or, for a parallel wave, once every system in flight has reported).
// Deferred structural changes are not applied here: the phase may run on a
// non-owning thread, so the world's owner flushes explicitly.
scheduler_run :: proc(s: ^Scheduler, phase: Phase, w: ^World, dt: f32) -> bool {
	if !s.finalized {
		if !scheduler_finalize(s) {return false}
	}
	for &wave in s.schedule[phase].waves {
		for h in wave.systems {
			sys := &s.systems[h]
			found.profile_scope(sys.name)
			if !sys.run(w, dt) {return false}
		}
	}
	return true
}
