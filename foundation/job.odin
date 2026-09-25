package foundation

import "core:sync"
import "core:thread"

// A small help-first job system. Tasks are pushed to one queue; workers and any
// thread blocked in `job_system_wait` pull from it, so a task may submit children
// and wait for them without deadlocking (the waiter helps run queued work).
//
// Counters isolate batches: a task decrements its own counter when it finishes,
// and completion wakes the waiters. The world stays single-owner; the scheduler
// only submits `.ANY` systems whose declared accesses do not conflict.

Job :: struct {
	run:     proc(data: rawptr),
	data:    rawptr,
	counter: ^Job_Counter,
}

Job_Counter :: struct {
	remaining: i32,
	js:        ^Job_System,
}

Job_System :: struct {
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]Job,
	workers:  [dynamic]^thread.Thread,
	shutdown: bool,
}

@(private)
_Worker_Data :: struct {
	js:    ^Job_System,
	index: int,
}

// Thread-local nesting depth of `_job_run`. Non-zero means the current thread is
// executing a job task, which the ECS uses to reject structural changes.
@(thread_local)
_job_task_depth: int

in_job_task :: proc() -> bool {
	return _job_task_depth > 0
}

job_system_init :: proc(js: ^Job_System, worker_count: int) {
	if len(js.workers) > 0 {return}
	count := worker_count
	if count <= 0 {count = 4}
	js.workers = make([dynamic]^thread.Thread, count)
	for i in 0 ..< count {
		data := new(_Worker_Data)
		data^ = {js = js, index = i}
		t := thread.create(_job_worker_main, .Normal, "job-worker")
		t.data = data
		js.workers[i] = t
		thread.start(t)
	}
}

job_system_destroy :: proc(js: ^Job_System) {
	if len(js.workers) == 0 {return}
	sync.mutex_lock(&js.mutex)
	js.shutdown = true
	sync.cond_broadcast(&js.cond)
	sync.mutex_unlock(&js.mutex)
	for t in js.workers {
		thread.join(t)
		free(t.data)
		thread.destroy(t)
	}
	// `delete` frees the backing but leaves the header pointing at it; clear the
	// arrays so a later `job_system_init` cannot append into freed memory.
	delete(js.workers)
	js.workers = {}
	delete(js.queue)
	js.queue = {}
	js.shutdown = false
}

job_counter_init :: proc(c: ^Job_Counter, js: ^Job_System, count: int) {
	c.remaining = i32(count)
	c.js = js
}

job_counter_add :: proc(c: ^Job_Counter, n: int) {
	sync.atomic_add(&c.remaining, i32(n))
}

job_system_submit :: proc(
	js: ^Job_System,
	run: proc(data: rawptr),
	data: rawptr,
	counter: ^Job_Counter,
) {
	sync.mutex_lock(&js.mutex)
	append(&js.queue, Job{run = run, data = data, counter = counter})
	sync.cond_signal(&js.cond)
	sync.mutex_unlock(&js.mutex)
}

// Appends a batch of tasks under a single lock and wakes the workers once. Used
// by the chunked `parallel_for`, where one lock per task would dominate.
job_system_submit_batch :: proc(js: ^Job_System, jobs: []Job, counter: ^Job_Counter) {
	if len(jobs) == 0 {return}
	sync.mutex_lock(&js.mutex)
	for job in jobs {
		append(&js.queue, Job{run = job.run, data = job.data, counter = counter})
	}
	sync.cond_broadcast(&js.cond)
	sync.mutex_unlock(&js.mutex)
}

// Blocks until `counter` reaches zero, running queued tasks while it waits. Any
// thread may call this, including one already running a task (nested wait).
job_system_wait :: proc(js: ^Job_System, counter: ^Job_Counter) {
	for {
		if sync.atomic_load(&counter.remaining) <= 0 {return}
		if _job_try_run_one(js) {continue}
		sync.mutex_lock(&js.mutex)
		if sync.atomic_load(&counter.remaining) <= 0 {
			sync.mutex_unlock(&js.mutex)
			return
		}
		if len(js.queue) > 0 {
			sync.mutex_unlock(&js.mutex)
			continue
		}
		sync.cond_wait(&js.cond, &js.mutex)
		sync.mutex_unlock(&js.mutex)
	}
}

// Runs one queued task if there is any, helping progress without blocking.
// Returns false when the queue is empty. Used by a runner that is otherwise
// idle so it does not just sleep on a wakeup.
job_system_try_run_one :: proc(js: ^Job_System) -> bool {
	return _job_try_run_one(js)
}

@(private)
_job_try_run_one :: proc(js: ^Job_System) -> bool {
	sync.mutex_lock(&js.mutex)
	if len(js.queue) == 0 {
		sync.mutex_unlock(&js.mutex)
		return false
	}
	job := pop(&js.queue)
	sync.mutex_unlock(&js.mutex)
	_job_run(js, job)
	return true
}

@(private)
_job_run :: proc(js: ^Job_System, job: Job) {
	_job_task_depth += 1
	defer {
		_job_task_depth -= 1
		if job.counter != nil {_job_counter_done(job.counter)}
	}
	job.run(job.data)
}

@(private)
_job_counter_done :: proc(c: ^Job_Counter) {
	if sync.atomic_sub(&c.remaining, 1) == 1 {
		js := c.js
		if js == nil {return}
		sync.mutex_lock(&js.mutex)
		sync.cond_broadcast(&js.cond)
		sync.mutex_unlock(&js.mutex)
	}
}

@(private)
_job_worker_main :: proc(t: ^thread.Thread) {
	data := cast(^_Worker_Data)t.data
	js := data.js
	profile_thread_ensure()
	profile_thread_name_id("job-worker", data.index)
	defer profile_thread_destroy()
	for {
		sync.mutex_lock(&js.mutex)
		for !js.shutdown && len(js.queue) == 0 {
			sync.cond_wait(&js.cond, &js.mutex)
		}
		if js.shutdown {
			sync.mutex_unlock(&js.mutex)
			break
		}
		job := pop(&js.queue)
		sync.mutex_unlock(&js.mutex)
		_job_run(js, job)
	}
}

// --- Parallel for --------------------------------------------------------

PARALLEL_MIN :: 64
PARALLEL_CHUNKS_PER_WORKER :: 8
PARALLEL_MIN_CHUNK :: 8

@(private)
_Range_State :: struct {
	fn:    proc(index: int, data: rawptr),
	data:  rawptr,
	count: int,
	chunk: int,
	next:  i32,
}

// Runs `fn(i, data)` for `i` in `[0, count)` across the pool. A handful of driver
// tasks share an atomic cursor, so the work stays dynamically balanced while the
// task/counter overhead stays bounded. Nested calls are safe: a driver blocked in
// `job_system_wait` helps run queued work.
job_system_parallel_for :: proc(
	js: ^Job_System,
	fn: proc(index: int, data: rawptr),
	data: rawptr,
	count: int,
) {
	if count <= 0 {return}
	if count < PARALLEL_MIN || js == nil || len(js.workers) == 0 {
		for i in 0 ..< count {fn(i, data)}
		return
	}
	worker_count := len(js.workers)
	if worker_count > count {worker_count = count}
	target_chunks := worker_count * PARALLEL_CHUNKS_PER_WORKER
	chunk := (count + target_chunks - 1) / target_chunks
	if chunk < PARALLEL_MIN_CHUNK {chunk = PARALLEL_MIN_CHUNK}
	chunks := (count + chunk - 1) / chunk
	drivers := worker_count
	if drivers > chunks {drivers = chunks}

	state := _Range_State {
		fn    = fn,
		data  = data,
		count = count,
		chunk = chunk,
		next  = 0,
	}
	counter: Job_Counter
	job_counter_init(&counter, js, drivers)
	sync.mutex_lock(&js.mutex)
	for _ in 0 ..< drivers {
		append(&js.queue, Job{run = _range_driver, data = &state, counter = &counter})
	}
	sync.cond_broadcast(&js.cond)
	sync.mutex_unlock(&js.mutex)
	job_system_wait(js, &counter)
}

@(private)
_range_driver :: proc(data: rawptr) {
	state := cast(^_Range_State)data
	profile_scope_args(
		"parallel_for",
		"count=%d chunk=%d",
		{state.count, state.chunk},
	)
	for {
		start := int(sync.atomic_add(&state.next, i32(state.chunk)))
		if start >= state.count {break}
		end := min(start + state.chunk, state.count)
		for i in start ..< end {state.fn(i, state.data)}
	}
}

// --- Chunked parallel for -------------------------------------------------

// Upper bound on chunk tasks per range; keeps the per-call descriptor arrays on
// the stack. Real chunk counts are the worker count times
// `PARALLEL_CHUNKS_PER_WORKER`, far below this.
MAX_CHUNKS :: 1024

@(private)
_Chunk :: struct {
	fn:    proc(index: int, data: rawptr),
	data:  rawptr,
	start: int,
	end:   int,
}

@(private)
_run_chunk :: proc(data: rawptr) {
	c := cast(^_Chunk)data
	for i in c.start ..< c.end {c.fn(i, c.data)}
}

// Runs `fn(i, data)` for `i` in `[0, count)` as one job per chunk, so every chunk
// is an individually schedulable task. The caller waits (and helps) on a counter
// that spans the chunks. Chunk descriptors live on the caller's stack, which is
// valid because the call blocks until every chunk has finished.
job_system_parallel_chunks :: proc(
	js: ^Job_System,
	fn: proc(index: int, data: rawptr),
	data: rawptr,
	count: int,
) {
	if count <= 0 {return}
	if count < PARALLEL_MIN || js == nil || len(js.workers) == 0 {
		for i in 0 ..< count {fn(i, data)}
		return
	}
	worker_count := len(js.workers)
	if worker_count > count {worker_count = count}
	target_chunks := worker_count * PARALLEL_CHUNKS_PER_WORKER
	chunk := (count + target_chunks - 1) / target_chunks
	if chunk < PARALLEL_MIN_CHUNK {chunk = PARALLEL_MIN_CHUNK}
	chunks := (count + chunk - 1) / chunk
	if chunks > MAX_CHUNKS {
		chunk = (count + MAX_CHUNKS - 1) / MAX_CHUNKS
		chunks = (count + chunk - 1) / chunk
	}

	ctx: [MAX_CHUNKS]_Chunk = ---
	jobs: [MAX_CHUNKS]Job = ---
	counter: Job_Counter
	job_counter_init(&counter, js, chunks)
	for k in 0 ..< chunks {
		start := k * chunk
		ctx[k] = _Chunk {
			fn    = fn,
			data  = data,
			start = start,
			end   = min(start + chunk, count),
		}
		jobs[k] = Job{run = _run_chunk, data = &ctx[k], counter = &counter}
	}
	job_system_submit_batch(js, jobs[:chunks], &counter)
	job_system_wait(js, &counter)
}
