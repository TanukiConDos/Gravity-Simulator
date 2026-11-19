package vk

import gfx "../shared"
import "vendor:vulkan"

// Neutral compute entry points for a producer that must not import the Vulkan
// backend (the GPU physics solver, through the front's proxy). Every procedure
// takes and returns the plain handles of `shared/gfx.odin`; the Vulkan types and
// flag translation stay in this file.

@(private)
_compute_of :: proc(c: gfx.Compute) -> ^Compute {
	return cast(^Compute)rawptr(c)
}

// compute_attach opens a compute context on the backend's device. The context
// borrows the device (`owns_device = false`) and refuses to attach when compute
// would alias the graphics queue: the two threads would share one queue.
compute_attach :: proc(backend: ^Backend) -> (result: ^Compute, ok: bool) {
	if backend == nil || !backend.gpu.has_compute || backend.gpu.compute_queue_is_shared {
		return nil, false
	}
	self := new(Compute)
	committed := false
	defer if !committed {
		compute_close(self)
		free(self)
	}
	self.gpu = &backend.gpu
	compute_open(self) or_return
	committed = true
	return self, true
}

// compute_detach closes a context created by `compute_attach`. The device stays
// with the backend.
compute_detach :: proc(self: ^Compute) {
	if self == nil {return}
	compute_close(self)
	free(self)
}

// compute_handle converts a context into the opaque handle producers hold. A
// headless context built by `compute_init_headless` converts the same way, so
// the producer API is identical in the app and in the bench/tests.
compute_handle :: proc(self: ^Compute) -> gfx.Compute {
	return gfx.Compute(rawptr(self))
}

// compute_device_info describes the context's device.
compute_device_info :: proc(c: gfx.Compute) -> gfx.Info {
	self := _compute_of(c)
	if self == nil || self.gpu == nil {return {}}
	info := compute_info(self)
	return gfx.Info {
		device_name = info.device_name,
		dedicated_queue = info.dedicated_queue,
		timestamp_valid = info.timestamp_valid,
	}
}

// compute_timeline_handle is the timeline every submission signals.
compute_timeline_handle :: proc(c: gfx.Compute) -> gfx.Semaphore {
	self := _compute_of(c)
	if self == nil || self.gpu == nil {return 0}
	return gfx.Semaphore(u64(self.timeline.semaphore))
}

// compute_semaphore_value reads a timeline semaphore's counter without waiting.
compute_semaphore_value :: proc(c: gfx.Compute, semaphore: gfx.Semaphore) -> u64 {
	self := _compute_of(c)
	if self == nil || self.gpu == nil {return 0}
	return semaphore_counter(self.gpu.device, vulkan.Semaphore(u64(semaphore)))
}

// compute_buffer_create allocates a buffer through the context's allocator.
// `sharing = .RENDER` makes it CONCURRENT across the graphics and compute
// families when they differ and the context borrows a renderer's device.
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
	self := _compute_of(c)
	if self == nil || self.gpu == nil {return {}, false}

	flags: vulkan.BufferUsageFlags
	if .STORAGE in usage {flags += {.STORAGE_BUFFER}}
	if .TRANSFER_SRC in usage {flags += {.TRANSFER_SRC}}
	if .TRANSFER_DST in usage {flags += {.TRANSFER_DST}}
	if .INDIRECT in usage {flags += {.INDIRECT_BUFFER}}
	kind := memory == .HOST ? MemoryKind.HostVisible : MemoryKind.DeviceLocal

	families: [2]u32
	family_list: []u32
	if sharing == .RENDER && !self.owns_device {
		graphics := self.gpu.graphics_queue_family_index
		compute_family := self.gpu.compute_queue_family_index
		if graphics != compute_family {
			families = {graphics, compute_family}
			family_list = families[:]
		}
	}

	buffer := new(Buffer)
	buffer^, ok = buffer_init_shared(self.gpu, vulkan.DeviceSize(bytes), flags, kind, family_list)
	if !ok {
		free(buffer)
		return {}, false
	}
	return gfx.Buffer{id = rawptr(buffer), size = u64(buffer.size), mapped = buffer.mapped}, true
}

// compute_buffer_destroy releases a buffer created by compute_buffer_create.
compute_buffer_destroy :: proc(c: gfx.Compute, buffer: ^gfx.Buffer) {
	if buffer == nil || buffer.id == nil {return}
	owned := cast(^Buffer)buffer.id
	buffer_destroy(owned)
	free(owned)
	buffer^ = {}
}

// compute_pipeline_create registers a compute pipeline together with the
// external push-descriptor bindings the producer fills per pass. `bindings` are
// the shader's storage-buffer binding indices (set 0).
compute_pipeline_create :: proc(
	c: gfx.Compute,
	name, shader: string,
	bindings: []u32,
) -> (
	result: gfx.Pipeline,
	ok: bool,
) {
	self := _compute_of(c)
	if self == nil || self.gpu == nil {return 0, false}

	specs := make([]Push_Binding_Spec, len(bindings), context.temp_allocator)
	for binding, i in bindings {
		specs[i] = {set = 0, binding = binding, descriptor = .STORAGE_BUFFER, external = true}
	}

	id, built := pipeline_registry_add_compute(
		&self.pipelines,
		name,
		Compute_Config{shaders = []Shader_Spec{{path = shader}}},
	)
	if !built {return 0, false}

	pipeline := pipeline_registry_get(&self.pipelines, id)
	push, push_ok := push_descriptors_init(self.gpu, specs)
	if !push_ok {return 0, false}
	if !push_descriptors_validate(&push, pipeline) {
		push_descriptors_destroy(&push)
		return 0, false
	}

	append(&self.producers, Producer_Pipeline{id = id, push = push})
	return gfx.Pipeline(len(self.producers) - 1), true
}

@(private)
_producer_pipeline :: proc(self: ^Compute, pipeline: gfx.Pipeline) -> (^Pipeline, ^Push_Descriptors) {
	assert(u32(pipeline) < u32(len(self.producers)), "compute pipeline handle is not registered")
	entry := &self.producers[u32(pipeline)]
	return pipeline_registry_get(&self.pipelines, entry.id), &entry.push
}

// compute_start reserves a submission slot and opens its command buffer.
compute_start :: proc(c: gfx.Compute) -> gfx.Command {
	self := _compute_of(c)
	assert(self != nil, "compute_start on a null context")
	cmd, slot := compute_begin(self)
	return gfx.Command{id = rawptr(cmd), slot = u32(slot)}
}

// compute_finish closes and submits the slot, returning the timeline value that
// signals completion.
compute_finish :: proc(c: gfx.Compute, cmd: gfx.Command) -> u64 {
	self := _compute_of(c)
	assert(self != nil, "compute_finish on a null context")
	return compute_submit(self, int(cmd.slot))
}

// compute_await blocks until the timeline reaches `value`.
compute_await :: proc(c: gfx.Compute, value: u64) {
	self := _compute_of(c)
	if self == nil {return}
	compute_wait(self, value)
}

// compute_barrier transitions a buffer between the two access scopes.
compute_barrier :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	buffer: gfx.Buffer,
	offset, size: u64,
	src, dst: gfx.Stage,
) {
	self := _compute_of(c)
	if self == nil || buffer.id == nil {return}
	src_stage, src_access := _stage_masks(src)
	dst_stage, dst_access := _stage_masks(dst)
	buffer_barrier(
		_command(cmd),
		_buffer_handle(buffer),
		vulkan.DeviceSize(offset),
		vulkan.DeviceSize(size),
		src_stage,
		dst_stage,
		src_access,
		dst_access,
	)
}

// compute_advance makes compute writes visible to the next compute pass, and to
// indirect dispatch reads when `indirect` is set (the tree build's per-level
// dispatch counts).
compute_advance :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	buffer: gfx.Buffer,
	offset, size: u64,
	indirect: bool,
) {
	self := _compute_of(c)
	if self == nil || buffer.id == nil {return}
	dst_stage: vulkan.PipelineStageFlags2 = {.COMPUTE_SHADER}
	dst_access: vulkan.AccessFlags2 = {.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE}
	if indirect {
		dst_stage += {.DRAW_INDIRECT}
		dst_access += {.INDIRECT_COMMAND_READ}
	}
	buffer_barrier(
		_command(cmd),
		_buffer_handle(buffer),
		vulkan.DeviceSize(offset),
		vulkan.DeviceSize(size),
		{.COMPUTE_SHADER},
		dst_stage,
		{.SHADER_STORAGE_WRITE},
		dst_access,
	)
}

// compute_copy records a buffer-to-buffer copy. Offsets let a producer read a
// region out of an arena buffer (the tree build's node array).
compute_copy :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	src: gfx.Buffer,
	src_offset: u64,
	dst: gfx.Buffer,
	dst_offset: u64,
	bytes: u64,
) {
	if src.id == nil || dst.id == nil {return}
	region := vulkan.BufferCopy {
		srcOffset = vulkan.DeviceSize(src_offset),
		dstOffset = vulkan.DeviceSize(dst_offset),
		size      = vulkan.DeviceSize(bytes),
	}
	vulkan.CmdCopyBuffer(_command(cmd), _buffer_handle(src), _buffer_handle(dst), 1, &region)
}

// compute_fill_zero clears a region (the tree build's contact counter).
compute_fill_zero :: proc(cmd: gfx.Command, buffer: gfx.Buffer, offset, bytes: u64) {
	if buffer.id == nil {return}
	vulkan.CmdFillBuffer(
		_command(cmd),
		_buffer_handle(buffer),
		vulkan.DeviceSize(offset),
		vulkan.DeviceSize(bytes),
		0,
	)
}

// compute_dispatch runs a direct dispatch.
compute_dispatch :: proc(cmd: gfx.Command, groups: [3]u32) {
	vulkan.CmdDispatch(_command(cmd), groups[0], groups[1], groups[2])
}

// compute_dispatch_indirect runs a dispatch whose group counts are read from
// `buffer` at `offset`.
compute_dispatch_indirect :: proc(cmd: gfx.Command, buffer: gfx.Buffer, offset: u64) {
	if buffer.id == nil {return}
	vulkan.CmdDispatchIndirect(_command(cmd), _buffer_handle(buffer), vulkan.DeviceSize(offset))
}

// compute_bind_pipeline makes a producer pipeline current.
compute_bind_pipeline :: proc(c: gfx.Compute, cmd: gfx.Command, pipeline: gfx.Pipeline) {
	self := _compute_of(c)
	if self == nil {return}
	pipe, _ := _producer_pipeline(self, pipeline)
	pipeline_bind_compute(pipe, _command(cmd))
}

// compute_push_constants uploads the pass's push-constant block.
compute_push_constants :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	pipeline: gfx.Pipeline,
	data: rawptr,
	size: u32,
) {
	self := _compute_of(c)
	if self == nil {return}
	pipe, _ := _producer_pipeline(self, pipeline)
	pipeline_push_constants(pipe, _command(cmd), data, size)
}

// compute_bind_buffers points the pipeline's external bindings at the pass's
// buffers and pushes them. The slot comes from the command being recorded.
compute_bind_buffers :: proc(
	c: gfx.Compute,
	cmd: gfx.Command,
	pipeline: gfx.Pipeline,
	binds: []gfx.Bind,
) {
	self := _compute_of(c)
	if self == nil || len(binds) == 0 {return}
	pipe, push := _producer_pipeline(self, pipeline)
	for bind in binds {
		push_descriptors_bind_buffer(
			push,
			0,
			bind.binding,
			cmd.slot,
			_buffer_handle(bind.buffer),
			vulkan.DeviceSize(bind.offset),
			vulkan.DeviceSize(bind.size),
		)
	}
	push_descriptors_flush(push, _command(cmd), pipe.layout, cmd.slot)
}

@(private)
_command :: proc(cmd: gfx.Command) -> vulkan.CommandBuffer {
	return vulkan.CommandBuffer(cmd.id)
}

@(private)
_stage_masks :: proc(stage: gfx.Stage) -> (vulkan.PipelineStageFlags2, vulkan.AccessFlags2) {
	switch stage {
	case .HOST_WRITE:
		return {.HOST}, {.HOST_WRITE}
	case .TRANSFER_READ:
		return {.TRANSFER}, {.TRANSFER_READ}
	case .TRANSFER_WRITE:
		return {.TRANSFER}, {.TRANSFER_WRITE}
	case .SHADER_READ:
		return {.COMPUTE_SHADER}, {.SHADER_STORAGE_READ}
	case .SHADER_RW:
		return {.COMPUTE_SHADER}, {.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE}
	case .SHADER_WRITE:
		return {.COMPUTE_SHADER}, {.SHADER_STORAGE_WRITE}
	case .HOST_READ:
		return {.HOST}, {.HOST_READ}
	}
	return {}, {}
}
