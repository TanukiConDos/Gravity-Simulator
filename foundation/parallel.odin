package foundation

import "core:sync"
import "core:thread"

PARALLEL_MIN :: 64

// Work is split into chunks so a fork-join job balances across workers. The
// chunk size adapts to the job: aim for PARALLEL_CHUNKS_PER_WORKER chunks per
// worker, but never below PARALLEL_MIN_CHUNK (bounds atomic/scheduling overhead).
PARALLEL_CHUNKS_PER_WORKER :: 8
PARALLEL_MIN_CHUNK :: 8

parallel_state: struct {
	initialized: bool,
	workers:     [dynamic]^thread.Thread,
	work_ready:  sync.Sema,
	work_done:   sync.Sema,
	job_fn:      proc(index: int, data: rawptr),
	job_data:    rawptr,
	job_count:   int,
	chunk:       int,
	next_chunk:  int,
	shutdown:    bool,
}

parallel_init :: proc(worker_count: int) {
	if parallel_state.initialized {return}
	count := worker_count
	if count <= 0 {count = 4}
	parallel_state.workers = make([dynamic]^thread.Thread, count)
	for i in 0 ..< count {
		t := thread.create(_parallel_worker_main, .Normal, "parallel-worker")
		parallel_state.workers[i] = t
		thread.start(t)
	}
	parallel_state.initialized = true
}

parallel_destroy :: proc() {
	if !parallel_state.initialized {return}
	parallel_state.shutdown = true
	for i in 0 ..< len(parallel_state.workers) {
		sync.sema_post(&parallel_state.work_ready)
	}
	for t in parallel_state.workers {
		thread.join(t)
		thread.destroy(t)
	}
	delete(parallel_state.workers)
	parallel_state.initialized = false
	parallel_state.shutdown = false
}

parallel_for :: proc(fn: proc(index: int, data: rawptr), data: rawptr, count: int) {
	if count <= 0 {return}
	if count < PARALLEL_MIN || !parallel_state.initialized || len(parallel_state.workers) == 0 {
		for i in 0 ..< count {fn(i, data)}
		return
	}

	parallel_state.job_fn = fn
	parallel_state.job_data = data
	parallel_state.job_count = count
	worker_count := len(parallel_state.workers)
	if worker_count > count {
		worker_count = count
	}
	target_chunks := worker_count * PARALLEL_CHUNKS_PER_WORKER
	chunk := (count + target_chunks - 1) / target_chunks
	if chunk < PARALLEL_MIN_CHUNK {chunk = PARALLEL_MIN_CHUNK}
	parallel_state.chunk = chunk
	parallel_state.next_chunk = 0
	for i in 0 ..< worker_count {
		sync.sema_post(&parallel_state.work_ready)
	}
	for i in 0 ..< worker_count {
		sync.sema_wait(&parallel_state.work_done)
	}
}

@(private)
_parallel_worker_main :: proc(t: ^thread.Thread) {
	for {
		sync.sema_wait(&parallel_state.work_ready)
		if parallel_state.shutdown {break}

		profile_thread_ensure()
		profile_thread_name("worker")
		{
			defer profile_thread_flush()
			profile_scope("parallel_for")

			fn := parallel_state.job_fn
			data := parallel_state.job_data
			count := parallel_state.job_count
			chunk := parallel_state.chunk

			for {
				start := sync.atomic_add(&parallel_state.next_chunk, chunk)
				if start >= count {break}
				end := min(start + chunk, count)
				for i in start ..< end {
					fn(i, data)
				}
			}

			sync.sema_post(&parallel_state.work_done)
		}
	}
}
