package graphic

import gfx "engine:graphics/shared"
import vk "engine:graphics/backend"

// The physics-facing compute API. A module that needs GPU work (the GPU gravity
// solver) describes it with the plain handles of `shared/gfx.odin` and calls
// these procedures; the GPU sequencing — staging, barriers, pass recording,
// dispatch — lives here, and the Vulkan calls stay in the backend. The front is
// the only integration point: no physics package imports `vk` or `vulkan`.

// renderer_compute returns the renderer's compute context, attaching one to the
// backend's device on first use. It returns a null handle when the device has no
// separately usable compute queue; callers then fall back to the CPU.
renderer_compute :: proc(self: ^Renderer) -> gfx.Compute {
	if self == nil || self.backend == nil {return nil}
	if self.compute == nil {
		attached, ok := vk.compute_attach(self.backend)
		if !ok {return nil}
		self.compute = attached
	}
	return vk.compute_handle(self.compute)
}

// compute_info describes the context's device.
compute_info :: proc(c: gfx.Compute) -> gfx.Info {
	return vk.compute_device_info(c)
}

// compute_timeline is the timeline every submission of this context signals.
compute_timeline :: proc(c: gfx.Compute) -> gfx.Semaphore {
	return vk.compute_timeline_handle(c)
}

// compute_semaphore_value reads a timeline semaphore's counter without waiting.
// The render-view vending protocol uses it to tell whether the frame that last
// read a render set has completed.
compute_semaphore_value :: proc(c: gfx.Compute, semaphore: gfx.Semaphore) -> u64 {
	return vk.compute_semaphore_value(c, semaphore)
}

// compute_buffer_create allocates a buffer the context's allocator owns.
compute_buffer_create :: proc(
	c: gfx.Compute,
	bytes: u64,
	usage: gfx.Usage,
	memory: gfx.Memory,
	sharing: gfx.Sharing,
) -> (
	result: gfx.Buffer,
	ok: bool,
) {
	return vk.compute_buffer_create(c, bytes, usage, memory, sharing)
}

// compute_buffer_destroy releases a buffer created by compute_buffer_create.
compute_buffer_destroy :: proc(c: gfx.Compute, buffer: ^gfx.Buffer) {
	vk.compute_buffer_destroy(c, buffer)
}

// compute_pipeline_create registers a compute pipeline. `bindings` are the
// shader's storage-buffer binding indices: the producer binds those per pass.
compute_pipeline_create :: proc(
	c: gfx.Compute,
	name, job: string,
	bindings: []u32,
) -> (
	result: gfx.Pipeline,
	ok: bool,
) {
	return vk.compute_pipeline_create(c, name, job, bindings)
}

// compute_reload_pipelines rebuilds the context's pipelines from the current
// SPIR-V. It must run on the context's submitting thread (the physics thread for
// the GPU gravity solver) and waits for the context timeline first.
compute_reload_pipelines :: proc(c: gfx.Compute) -> bool {
	return vk.compute_reload_pipelines(c)
}

// compute_begin reserves a submission slot and opens its command buffer.
compute_begin :: proc(c: gfx.Compute) -> gfx.Command {
	return vk.compute_start(c)
}

// compute_upload stages host data into a device buffer and leaves it visible to
// compute. `write` selects a read-write destination (the shader updates it in
// place); otherwise the compute pass only reads it.
compute_upload :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	host: gfx.Buffer,
	device: gfx.Buffer,
	bytes: u64,
	write := false,
) {
	vk.compute_barrier(c, cmd, host, 0, bytes, .HOST_WRITE, .TRANSFER_READ)
	vk.compute_copy(c, cmd, host, 0, device, 0, bytes)
	vk.compute_barrier(c, cmd, device, 0, bytes, .TRANSFER_WRITE, write ? .SHADER_RW : .SHADER_READ)
}

// compute_readback stages a device region into a host buffer the caller reads
// after the submission completes.
compute_readback :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	src: gfx.Buffer,
	src_offset: u64,
	dst: gfx.Buffer,
	dst_offset: u64,
	bytes: u64,
) {
	vk.compute_barrier(c, cmd, src, src_offset, bytes, .SHADER_WRITE, .TRANSFER_READ)
	vk.compute_copy(c, cmd, src, src_offset, dst, dst_offset, bytes)
	vk.compute_barrier(c, cmd, dst, dst_offset, bytes, .TRANSFER_WRITE, .HOST_READ)
}

// compute_zero clears a device region on the transfer engine, leaving it visible
// to compute.
compute_zero :: proc(c: gfx.Compute, cmd: gfx.Command, buffer: gfx.Buffer, offset, bytes: u64) {
	vk.compute_fill_zero(cmd, buffer, offset, bytes)
	vk.compute_barrier(c, cmd, buffer, offset, bytes, .TRANSFER_WRITE, .SHADER_RW)
}

// compute_advance orders compute writes before the next compute pass, and before
// indirect dispatch reads when `indirect` is set.
compute_advance :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	buffer: gfx.Buffer,
	offset, bytes: u64,
	indirect := false,
) {
	vk.compute_advance(c, cmd, buffer, offset, bytes, indirect)
}

// compute_pass records one dispatch: bind the pipeline, upload the push
// constants, point the descriptor bindings at this pass's buffers and dispatch
// (directly, or indirectly from `dispatch.indirect`).
compute_pass :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	pipeline: gfx.Pipeline,
	binds: []gfx.Bind,
	dispatch: gfx.Dispatch,
	push: rawptr = nil,
	push_bytes: u32 = 0,
) {
	vk.compute_bind_pipeline(c, cmd, pipeline)
	if push_bytes > 0 {
		vk.compute_push_constants(c, cmd, pipeline, push, push_bytes)
	}
	vk.compute_bind_buffers(c, cmd, pipeline, binds)
	if dispatch.indirect.id != nil {
		vk.compute_dispatch_indirect(cmd, dispatch.indirect, dispatch.offset)
	} else {
		vk.compute_dispatch(cmd, dispatch.groups)
	}
}

// compute_submit closes and submits the recording, returning the timeline value
// that signals its completion.
compute_submit :: proc(c: gfx.Compute, cmd: gfx.Command) -> u64 {
	return vk.compute_finish(c, cmd)
}

// compute_wait blocks until the context's timeline reaches `value`.
compute_wait :: proc(c: gfx.Compute, value: u64) {
	vk.compute_await(c, value)
}
