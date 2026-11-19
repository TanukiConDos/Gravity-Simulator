package gfx

// Plain-data vocabulary for GPU compute work, so a consumer (the GPU physics
// solver) can describe buffers and passes without importing the Vulkan backend.
//
// `Engine/Graphic/front` exposes the procedures that record and submit this
// work (`compute_buffer_create`, `compute_pass`, `compute_submit`, ...); the
// backend owns the Vulkan translation. Nothing here imports Vulkan, ECS or GLFW.

// Compute names the backend's compute context. Only the backend interprets it.
Compute :: distinct rawptr

// Command is one recording of a compute context's ring slot. `slot` is carried
// here so consumers never thread it through every call.
Command :: struct {
	id:   rawptr, // the backend's command buffer
	slot: u32,
}

// Pipeline is a confirmed compute pipeline plus its push-descriptor bindings.
// Context-local: only the context that created it may record it.
Pipeline :: distinct u64

// Semaphore is an opaque timeline semaphore handle. Consumers only pass it
// around (the renderer's frame timeline) or compare values read from it.
Semaphore :: distinct u64

// Buffer is a handle to a backend buffer. `size` and `mapped` are the only
// fields a producer needs: host-visible buffers stay mapped for their lifetime.
Buffer :: struct {
	id:     rawptr,
	size:   u64,
	mapped: rawptr,
}

Memory :: enum {
	DEVICE,
	HOST,
}

// Sharing declares whether another queue family reads the buffer.
// RENDER means "the graphics queue reads it too" (the vending render sets); the
// backend turns that into a CONCURRENT buffer when the families differ.
Sharing :: enum {
	EXCLUSIVE,
	RENDER,
}

Usage_Flag :: enum u8 {
	STORAGE,
	TRANSFER_SRC,
	TRANSFER_DST,
	INDIRECT,
}

Usage :: bit_set[Usage_Flag; u8]

// Stage is a memory-access scope for a buffer barrier. The backend expands each
// one into the pipeline-stage and access masks it stands for.
Stage :: enum u8 {
	HOST_WRITE, // host wrote it, a transfer reads it
	TRANSFER_READ, // a transfer reads what compute wrote
	TRANSFER_WRITE, // a transfer wrote it, compute reads it
	SHADER_READ, // compute reads it
	SHADER_RW, // compute reads and writes it
	SHADER_WRITE, // compute wrote it, a transfer reads it
	HOST_READ, // the host reads what a transfer wrote
}

// Bind points one descriptor binding at a producer-owned buffer for a pass.
Bind :: struct {
	binding: u32,
	buffer:  Buffer,
	offset:  u64,
	size:    u64,
}

// Dispatch describes a pass's invocation count. A non-nil `indirect.id` selects
// an indirect dispatch whose command is read from that buffer at `offset`.
Dispatch :: struct {
	groups:   [3]u32,
	indirect: Buffer,
	offset:   u64,
}

// Info is the compute context's device description.
Info :: struct {
	device_name:     string,
	dedicated_queue: bool,
	timestamp_valid: bool,
}
