package tests

import found "../foundation"
import "core:sync"
import "core:testing"

@(private)
g_job_sum: i32

@(private)
_job_add_one :: proc(data: rawptr) {
	v := (cast(^i32)data)^
	sync.atomic_add(&g_job_sum, v)
}

@(test)
test_job_system_tasks :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	g_job_sum = 0
	values: [128]i32
	for i in 0 ..< len(values) {values[i] = 1}
	counter: found.Job_Counter
	found.job_counter_init(&counter, &js, len(values))
	for i in 0 ..< len(values) {
		found.job_system_submit(&js, _job_add_one, &values[i], &counter)
	}
	found.job_system_wait(&js, &counter)
	testing.expect_value(t, sync.atomic_load(&g_job_sum), i32(128))
}

@(private)
_range_add :: proc(index: int, data: rawptr) {
	sync.atomic_add(cast(^i64)data, i64(index))
}

@(test)
test_job_system_parallel_for :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	sum: i64
	found.job_system_parallel_for(&js, _range_add, &sum, 10000)
	testing.expect_value(t, sum, i64(10000 * 9999 / 2))
}

@(private)
_Nested_Ctx :: struct {
	js: ^found.Job_System,
}

@(private)
g_nested_count: i32

@(private)
_nested_count_one :: proc(index: int, data: rawptr) {
	sync.atomic_add(cast(^i32)data, 1)
}

@(private)
_nested_task :: proc(data: rawptr) {
	ctx := cast(^_Nested_Ctx)data
	found.job_system_parallel_for(ctx.js, _nested_count_one, &g_nested_count, 1000)
}

// A task that submits and waits for its own children must not deadlock: the
// waiter helps run queued work while it waits.
@(test)
test_job_system_nested :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 4)
	defer found.job_system_destroy(&js)

	g_nested_count = 0
	ctx := _Nested_Ctx{js = &js}
	counter: found.Job_Counter
	found.job_counter_init(&counter, &js, 8)
	for _ in 0 ..< 8 {
		found.job_system_submit(&js, _nested_task, &ctx, &counter)
	}
	found.job_system_wait(&js, &counter)
	testing.expect_value(t, sync.atomic_load(&g_nested_count), i32(8000))
}

@(private)
g_job_flag_seen: bool

@(private)
_job_flag_task :: proc(data: rawptr) {
	g_job_flag_seen = found.in_job_task()
}

@(test)
test_job_in_task_flag :: proc(t: ^testing.T) {
	js: found.Job_System
	found.job_system_init(&js, 2)
	defer found.job_system_destroy(&js)

	g_job_flag_seen = false
	testing.expect(t, !found.in_job_task(), "caller is not in a task")
	counter: found.Job_Counter
	found.job_counter_init(&counter, &js, 1)
	found.job_system_submit(&js, _job_flag_task, nil, &counter)
	found.job_system_wait(&js, &counter)
	testing.expect(t, g_job_flag_seen, "a task reports in_job_task")
}
