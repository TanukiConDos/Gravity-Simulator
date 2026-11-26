package foundation

// Compatibility layer over the job system for the physics solver and the bench.
// `parallel_for` is the only entry point the physics hot path needs; it keeps its
// previous signature while the pool underneath is now a general job system.

@(private)
g_job_system: Job_System

parallel_init :: proc(worker_count: int) {
	job_system_init(&g_job_system, worker_count)
}

parallel_destroy :: proc() {
	job_system_destroy(&g_job_system)
}

// Number of pool workers; 0 when the pool is not initialized. Used to annotate
// solve spans with the parallelism actually available.
parallel_worker_count :: proc() -> int {
	return len(g_job_system.workers)
}

parallel_for :: proc(fn: proc(index: int, data: rawptr), data: rawptr, count: int) {
	job_system_parallel_chunks(&g_job_system, fn, data, count)
}

// The app-wide pool, shared by the physics solver and the system scheduler.
default_job_system :: proc() -> ^Job_System {
	return &g_job_system
}
