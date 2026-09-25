package ecs

import found "../../foundation"
import "core:log"
import "core:slice"
import "core:sync"

// Systems are plain procedures grouped by phase. The engine runs the PHYSICS
// phase on the physics thread and the RENDER phase on the graphics thread. A
// system returns false to abort the phase (a fatal error); the scheduler then
// stops dispatching and reports it to its caller.
//
// Within a phase execution is driven by a dependency graph resolved in
// `scheduler_finalize`: each system may declare which systems it must run after,
// and systems that touch the same components are serialised automatically. A
// system becomes ready when all of its predecessors have finished; ready
// `.CALLER` systems run on the phase thread and ready `.ANY` systems are
// dispatched to the job pool.
Phase :: enum {
	PHYSICS,
	RENDER,
}

// Stable identity of a registered system, returned by `scheduler_add`. Handles
// only exist for already-registered systems, so a dependency edge always points
// backwards and the graph cannot contain a cycle by construction.
System_Handle :: distinct u32

INVALID_SYSTEM :: System_Handle(0xFFFFFFFF)

// Where a ready system runs. `.CALLER` (default) is pinned to the phase thread
// and is the safe choice for anything that mutates structure, calls
// `parallel_for` or touches the renderer. `.ANY` may be dispatched to the job
// pool once its dependencies are done.
Affinity :: enum {
	CALLER,
	ANY,
}

// Declared data access. It is used to serialise `.ANY` systems that touch the
// same components (writer vs anything) by adding edges to the execution graph.
// Callers are trusted to keep the declaration truthful.
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

// Upper bound on registered systems: the executor keeps small per-run scratch
// arrays on the stack.
MAX_SYSTEMS :: 128

// Per-phase execution graph and its run scratch. `successors[i]` lists the
// systems that must wait for `i`, `deps[i]` is how many predecessors `i` has.
// The scratch (`deps_left`, `ready`, ...) is reset at the start of every
// `scheduler_run`; a phase has exactly one runner thread.
Phase_Schedule :: struct {
	order:      [dynamic]System_Handle,
	successors: [dynamic][dynamic]System_Handle,
	deps:       []int,
	deps_left:  []i32,
	ready:      [dynamic]System_Handle,
	to_run:     i32,
	in_flight:  i32,
	failed:     bool,
	mutex:      sync.Mutex,
	cond:       sync.Cond,
}

Scheduler :: struct {
	systems:   [dynamic]System,
	finalized: bool,
	jobs:      ^found.Job_System,
	schedule:  [Phase]Phase_Schedule,
}

scheduler_create :: proc(jobs: ^found.Job_System = nil) -> ^Scheduler {
	s := new(Scheduler)
	s.jobs = jobs
	return s
}

scheduler_destroy :: proc(s: ^Scheduler) {
	if s == nil {return}
	for &sys in s.systems {
		delete(sys.after)
		delete(sys.access.reads)
		delete(sys.access.writes)
	}
	delete(s.systems)
	for &sch in s.schedule {
		delete(sch.order)
		for &succ in sch.successors {delete(succ)}
		delete(sch.successors)
		delete(sch.deps)
		delete(sch.deps_left)
		delete(sch.ready)
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
	// The caller's `after`/`access` slices are usually compound literals on its
	// stack; copy them so the system does not point at a dead frame.
	for a in after {append(&sys.after, a)}
	sys.access.reads = slice.clone(access.reads)
	sys.access.writes = slice.clone(access.writes)
	h := System_Handle(len(s.systems))
	append(&s.systems, sys)
	return h
}

// Resolves the execution graph for every phase. Validates names and handles and
// returns false (and logs) on a duplicate name, an unknown handle, a handle from
// another phase, an `.ANY` system with no declared access, or `.ANY` outside the
// owner phase. Idempotent.
scheduler_finalize :: proc(s: ^Scheduler) -> bool {
	if s.finalized {return true}
	ok := true
	if len(s.systems) > MAX_SYSTEMS {
		log.errorf("[ECS] scheduler: %d systems exceed MAX_SYSTEMS", len(s.systems))
		return false
	}
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
		if sys.affinity == .ANY {
			if len(sys.access.reads) == 0 && len(sys.access.writes) == 0 {
				// Dynamic dispatch relies on the declared access to serialise
				// conflicting systems; an empty declaration is unsafe.
				log.errorf(
					"[ECS] scheduler: .ANY system %q declares no access",
					sys.name,
				)
				ok = false
			}
			if sys.phase != .PHYSICS {
				// The pool is shared across phases; only the world's owner phase
				// may run systems concurrently. A non-owner `.ANY` system would
				// race with the physics thread.
				log.errorf(
					"[ECS] scheduler: %q is .ANY outside the owner phase (PHYSICS-only)",
					sys.name,
				)
				ok = false
			}
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

// Builds one phase's graph: explicit `after` edges plus access-conflict edges
// between `.ANY` systems, then a deterministic topological order. Conflict
// edges are added forward along that order, so it stays acyclic and the relative
// order of conflicting systems is deterministic.
@(private)
_build_schedule :: proc(s: ^Scheduler, phase: Phase) -> bool {
	n := len(s.systems)
	sch := &s.schedule[phase]
	sch.successors = make([dynamic][dynamic]System_Handle, n)
	for i in 0 ..< n {sch.successors[i] = make([dynamic]System_Handle, 0, 4)}

	indices := make([dynamic]int, 0, 8)
	defer delete(indices)
	for i in 0 ..< n {
		if s.systems[i].phase == phase {append(&indices, i)}
	}

	// Explicit dependency edges.
	for i in indices {
		for a in s.systems[i].after {
			if int(a) >= n {continue}
			append(&sch.successors[int(a)], System_Handle(i))
		}
	}

	// Deterministic topological order (ties break by registration order).
	indeg := make([]int, n)
	defer delete(indeg)
	for i in 0 ..< n {
		for succ in sch.successors[i] {indeg[int(succ)] += 1}
	}
	order := make([dynamic]int, 0, len(indices))
	defer delete(order)
	done := make([]bool, n)
	defer delete(done)
	remaining := len(indices)
	for remaining > 0 {
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
		remaining -= 1
		for succ in sch.successors[pick] {
			if !done[int(succ)] {indeg[int(succ)] -= 1}
		}
	}

	// Access-conflict edges between `.ANY` systems, pointing forward in `order`.
	for ii in 0 ..< len(order) {
		for jj in ii + 1 ..< len(order) {
			a := &s.systems[order[ii]]
			b := &s.systems[order[jj]]
			if a.affinity != .ANY || b.affinity != .ANY {continue}
			if _conflicts(a, b) {
				append(&sch.successors[order[ii]], System_Handle(order[jj]))
			}
		}
	}

	// Final dependency counts and run scratch.
	clear(&sch.order)
	for h in order {append(&sch.order, System_Handle(h))}
	delete(sch.deps)
	sch.deps = make([]int, n)
	for i in 0 ..< n {
		for succ in sch.successors[i] {sch.deps[int(succ)] += 1}
	}
	delete(sch.deps_left)
	sch.deps_left = make([]i32, n)
	clear(&sch.ready)
	return true
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
		if len(sch.order) == 0 {continue}
		log.debugf("[ECS] schedule %v:", phase)
		for h in sch.order {
			log.debugf("  %q deps=%d", s.systems[h].name, sch.deps[h])
		}
	}
}

// Runs one phase to completion and returns false if any system failed.
//
// The call drives one runner (the phase thread): it takes the currently ready
// systems, runs `.CALLER` ones inline and submits `.ANY` ones to the pool, then
// sleeps until a completion makes more work ready. A completion decrements its
// successors and re-seeds the ready set. Deferred structural changes are not
// applied here: the owner thread flushes explicitly.
scheduler_run :: proc(s: ^Scheduler, phase: Phase, w: ^World, dt: f32) -> bool {
	if !s.finalized {
		if !scheduler_finalize(s) {return false}
	}
	exec := &s.schedule[phase]
	if len(exec.order) == 0 {return true}

	sync.mutex_lock(&exec.mutex)
	for i in 0 ..< len(exec.deps_left) {exec.deps_left[i] = i32(exec.deps[i])}
	clear(&exec.ready)
	exec.to_run = i32(len(exec.order))
	exec.in_flight = 0
	exec.failed = false
	for h in exec.order {
		if exec.deps_left[h] == 0 {append(&exec.ready, h)}
	}
	sync.mutex_unlock(&exec.mutex)

	tasks: [MAX_SYSTEMS]_Node_Task
	batch: [MAX_SYSTEMS]System_Handle

	for {
		sync.mutex_lock(&exec.mutex)
		if exec.to_run <= 0 && exec.in_flight <= 0 {
			sync.mutex_unlock(&exec.mutex)
			break
		}
		count := len(exec.ready)
		if count > MAX_SYSTEMS {count = MAX_SYSTEMS}
		for i in 0 ..< count {batch[i] = exec.ready[i]}
		clear(&exec.ready)
		sync.mutex_unlock(&exec.mutex)

		if count == 0 {
			// Help the pool while waiting so the phase does not lose a wakeup
			// round-trip to the OS. `try_run_one` takes the job lock, never
			// `exec.mutex`, so it is safe here.
			if s.jobs != nil && found.job_system_try_run_one(s.jobs) {
				continue
			}
			sync.mutex_lock(&exec.mutex)
			if exec.to_run <= 0 && exec.in_flight <= 0 {
				sync.mutex_unlock(&exec.mutex)
				break
			}
			if len(exec.ready) > 0 {
				sync.mutex_unlock(&exec.mutex)
				continue
			}
			if exec.to_run > 0 && exec.in_flight <= 0 {
				// No runnable work and nothing in flight: the graph stalled.
				log.errorf("[ECS] scheduler: stalled with %d systems left", exec.to_run)
				sync.mutex_unlock(&exec.mutex)
				break
			}
			sync.cond_wait(&exec.cond, &exec.mutex)
			sync.mutex_unlock(&exec.mutex)
			continue
		}

		for i in 0 ..< count {
			h := batch[i]
			sync.mutex_lock(&exec.mutex)
			failed := exec.failed
			if !failed {
				exec.to_run -= 1
				exec.in_flight += 1
			}
			sync.mutex_unlock(&exec.mutex)
			if failed {
				// Already dropping the rest of the phase; nothing to release.
				continue
			}
			sys := &s.systems[h]
			if sys.affinity == .ANY &&
			   s.jobs != nil &&
			   len(s.jobs.workers) > 0 &&
			   !ODIN_DEBUG {
				tasks[h] = _Node_Task {
					s      = s,
					exec   = exec,
					handle = h,
					w      = w,
					dt     = dt,
				}
				found.job_system_submit(s.jobs, _run_node_job, &tasks[h], nil)
			} else {
				found.profile_scope(sys.name)
				ok := sys.run(w, dt)
				_node_complete(s, exec, h, ok)
			}
		}
	}

	sync.mutex_lock(&exec.mutex)
	failed := exec.failed
	sync.mutex_unlock(&exec.mutex)
	return !failed
}

@(private)
_Node_Task :: struct {
	s:      ^Scheduler,
	exec:   ^Phase_Schedule,
	handle: System_Handle,
	w:      ^World,
	dt:     f32,
}

@(private)
_run_node_job :: proc(data: rawptr) {
	task := cast(^_Node_Task)data
	sys := &task.s.systems[task.handle]
	found.profile_scope(sys.name)
	ok := sys.run(task.w, task.dt)
	_node_complete(task.s, task.exec, task.handle, ok)
}

// Marks one dispatched node finished: when it succeeded, release its successors;
// otherwise set the phase's failed flag and drop all work that has not started.
// Always wakes the runner.
@(private)
_node_complete :: proc(
	s: ^Scheduler,
	exec: ^Phase_Schedule,
	h: System_Handle,
	ok: bool,
) {
	sync.mutex_lock(&exec.mutex)
	if !ok {
		exec.failed = true
		exec.to_run = 0
	} else if !exec.failed {
		for succ in exec.successors[h] {
			exec.deps_left[succ] -= 1
			if exec.deps_left[succ] == 0 {append(&exec.ready, succ)}
		}
	}
	exec.in_flight -= 1
	sync.cond_signal(&exec.cond)
	sync.mutex_unlock(&exec.mutex)
}
