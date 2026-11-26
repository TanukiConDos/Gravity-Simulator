package gfx

// The GPU instance-stream seam. A compute producer (the GPU physics solver)
// fills vertex-ready columns in device buffers and publishes them; the backend
// packs them into its instance vertex buffer before the main pass. Both sides
// speak only these plain structs, so the backend needs no engine types to draw
// the stream and the producer needs no backend types to publish it.

// InstanceData is the packed vertex layout the instance-pack shader writes and
// the vertex input reads. Kept as a plain struct so both sides agree on it.
InstanceData :: struct #packed {
	position: Vec3,
	radius:   f32,
	selected: i32,
	_pad:     [12]u8,
}

#assert(size_of(InstanceData) == 32)

// Stream_Handle names a GPU producer the backend can draw from. It is opaque:
// only the producer that registered `Stream_Ops` interprets it (typically its
// own object pointer), exactly like a Vulkan dispatch handle.
Stream_Handle :: distinct rawptr

// Stream_Ops is the producer's dispatch table. The backend calls `claim` once
// per frame while a producer is installed, and `release` when it stops holding a
// claimed stream (a newer one arrived, or the producer was uninstalled).
Stream_Ops :: struct {
	claim:   proc(handle: Stream_Handle) -> (stream: Instance_Stream, ok: bool),
	release: proc(handle: Stream_Handle, stream: Instance_Stream, frame_value: u64),
	// Optional: receives the frame timeline the backend signals, so the producer
	// can tell when the frame that last read a set has completed.
	set_frame_timeline: proc(handle: Stream_Handle, semaphore: Semaphore),
}

// Instance_Stream describes GPU-produced instance data. The producer owns the
// buffers and the vending protocol; the backend only packs them before the main
// pass and waits on `semaphore`/`value` at submit. The backend does not know who
// produces the stream or what `set` means.
Instance_Stream :: struct {
	bodies:     Buffer,
	radii:      Buffer,
	selected:   Buffer,
	live:       Buffer,
	mode:       u32,
	count:      int,
	capacity:   int,
	body_stride: int,
	semaphore:  Semaphore,
	value:      u64,
	// Opaque owner token; only the owner interprets it (it releases the set with
	// the frame value the backend last read it at).
	set:        u32,
	// Optional one-shot debug hook. The owner can verify the instance data it
	// supplied against its own reference without the backend knowing where that
	// reference comes from. Called once, after the slot's frame fence, before
	// the slot is recorded again.
	verify:      proc(user: rawptr, frame: u32, instances: [^]InstanceData, count: int),
	verify_user: rawptr,
}
