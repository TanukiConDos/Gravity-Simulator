package graphic

import "core:log"
import "core:slice"
import "core:time"
import "vendor:vulkan"

// Public compute context. It owns a device (headless) plus a command pool for
// the compute queue, a timeline semaphore and a small pipeline registry, and is
// the entry point bench stages (and later the GPU physics solver) use to run
// compute work. Every submission goes through the timeline: a slot is safe to
// record again once its previous value completed on the device.
//
// Only one thread submits to a context; the timeline's `value` is not atomic.
// A second context is cheap (it shares nothing), so one thread per context is
// the intended model.

// The bench probe shader; also the smallest end-to-end compute path.
@(private)
COMPUTE_PROBE_SHADER :: "Engine/Graphic/shader/compute_probe.spv"

Compute :: struct {
	// `gpu` is borrowed: it points at `device` for a headless context, or at the
	// renderer's device when a context is attached to it.
	gpu:          ^GPU,
	device:       GPU,
	owns_device:  bool,
	pipelines:    Pipeline_Registry,
	command_pool: CommandPool,
	timeline:     Timeline,
	slots:        [COMPUTE_SLOTS]Compute_Slot,
	next_slot:    u32,
}

@(private)
Compute_Slot :: struct {
	cmd:   vulkan.CommandBuffer,
	value: u64,
}

Compute_Info :: struct {
	device_name:         string,
	dedicated_queue:     bool,
	timestamp_period_ns: f32,
	timestamp_valid:     bool,
}

Compute_Probe :: struct {
	elements:             int,
	iterations:           int,
	samples:              int,
	gpu_ms_per_iteration: f64,
	gpu_time_available:   bool,
	roundtrip_ms:         f64,
	verified:             bool,
}

compute_init_headless :: proc() -> (result: ^Compute, ok: bool) {
	self := new(Compute)
	committed := false
	defer if !committed {compute_destroy(self)}

	self.device = gpu_init_headless() or_return
	self.gpu = &self.device
	self.owns_device = true
	_compute_open(self) or_return
	log.infof("[COMPUTE] Context ready on %s", compute_info(self).device_name)
	committed = true
	return self, true
}

// _compute_open creates the submission machinery (pipeline registry, command
// pool, timeline, slots) on `self.gpu`. It is the shared path of the headless
// context and of a context attached to the renderer's device.
@(private)
_compute_open :: proc(self: ^Compute) -> bool {
	self.pipelines = pipeline_registry_init(self.gpu)
	self.command_pool = command_pool_init_for(self.gpu, self.gpu.compute_queue_family_index, COMPUTE_SLOTS) or_return
	self.timeline = timeline_init(self.gpu) or_return
	for i in 0 ..< COMPUTE_SLOTS {self.slots[i].cmd = self.command_pool.command_buffers[i]}
	return true
}

// _compute_close waits for in-flight work and destroys the submission
// machinery. The device itself is left alone: it may belong to the renderer.
@(private)
_compute_close :: proc(self: ^Compute) {
	if self.gpu == nil {return}
	gpu_wait(self.gpu)
	timeline_destroy(&self.timeline)
	command_pool_destroy(&self.command_pool)
	pipeline_registry_destroy(&self.pipelines)
	self.gpu = nil
}

compute_destroy :: proc(self: ^Compute) {
	if self == nil {return}
	_compute_close(self)
	if self.owns_device {gpu_destroy(&self.device)}
	free(self)
}

compute_info :: proc(self: ^Compute) -> Compute_Info {
	return Compute_Info {
		device_name = string(self.gpu.device_name[:self.gpu.device_name_len]),
		dedicated_queue = self.gpu.compute_queue_is_dedicated,
		timestamp_period_ns = self.gpu.timestamp_period_ns,
		timestamp_valid = self.gpu.compute_timestamp_bits > 0 && self.gpu.timestamp_period_ns > 0,
	}
}

// compute_probe runs `samples` transfer -> dispatch x iterations -> transfer
// round trips and verifies the output. It reports the median GPU time per
// dispatch (timestamp queries) and the median host round trip (submit to
// completion), which is the per-tick latency floor the physics solver inherits.
compute_probe :: proc(self: ^Compute, elements, iterations, samples: int) -> (result: Compute_Probe, ok: bool) {
	info := compute_info(self)
	if elements <= 0 || iterations <= 0 || samples <= 0 {
		log.errorf("[COMPUTE] probe requires positive elements/iterations/samples")
		return {}, false
	}

	pipeline_id, built := pipeline_registry_add_compute(
		&self.pipelines,
		"probe",
		Compute_Config{shaders = []Shader_Spec{{path = COMPUTE_PROBE_SHADER}}},
	)
	if !built {return {}, false}
	pipeline := pipeline_registry_get(&self.pipelines, pipeline_id)
	workgroup := pipeline.workgroup_size
	if workgroup[0] == 0 {
		log.errorf("[COMPUTE] probe shader has no workgroup size")
		return {}, false
	}

	push := push_descriptors_init(
		self.gpu,
		[]Push_Binding_Spec {
			{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
			{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		},
	) or_return
	defer push_descriptors_destroy(&push)
	if !push_descriptors_validate(&push, pipeline) {return {}, false}

	size := vulkan.DeviceSize(elements * size_of(f32))
	in_host := buffer_init(self.gpu, size, {.TRANSFER_SRC}, .HostVisible) or_return
	defer buffer_destroy(&in_host)
	out_host := buffer_init(self.gpu, size, {.TRANSFER_DST}, .HostVisible) or_return
	defer buffer_destroy(&out_host)
	in_device := buffer_init(self.gpu, size, {.STORAGE_BUFFER, .TRANSFER_DST}, .DeviceLocal) or_return
	defer buffer_destroy(&in_device)
	out_device := buffer_init(self.gpu, size, {.STORAGE_BUFFER, .TRANSFER_SRC}, .DeviceLocal) or_return
	defer buffer_destroy(&out_device)

	// Small integers keep `x * 2 + 1` exactly representable, so verification is
	// an equality check and FMA contraction cannot change the result.
	input := cast([^]f32)in_host.mapped
	for i in 0 ..< elements {input[i] = f32(i % 512)}

	use_timestamps := info.timestamp_valid
	timestamps: Timestamps
	if use_timestamps {
		timestamps = timestamps_init(self.gpu, 2) or_return
	}
	// At procedure scope on purpose: a defer inside the `if` would run when the
	// block ends (Odin defers are block-scoped) and destroy the pool early.
	defer if use_timestamps {timestamps_destroy(&timestamps)}

	gpu_times := make([dynamic]f64, 0, samples)
	defer delete(gpu_times)
	roundtrips := make([dynamic]f64, 0, samples)
	defer delete(roundtrips)
	verified := true

	element_count := u32(elements)
	groups := u32((elements + int(workgroup[0]) - 1) / int(workgroup[0]))

	for _ in 0 ..< samples {
		cmd, slot := compute_begin(self)

		if use_timestamps {
			vulkan.CmdResetQueryPool(cmd, timestamps.pool, 0, 2)
			timestamps_write(&timestamps, cmd, 0)
		}

		buffer_barrier(cmd, in_host.buffer, 0, size, {.HOST}, {.TRANSFER}, {.HOST_WRITE}, {.TRANSFER_READ})
		gpu_copy_buffer(self.gpu, in_host.buffer, in_device.buffer, size, cmd)
		buffer_barrier(cmd, in_device.buffer, 0, size, {.TRANSFER}, {.COMPUTE_SHADER}, {.TRANSFER_WRITE}, {.SHADER_STORAGE_READ})

		pipeline_bind_compute(pipeline, cmd)
		pipeline_push_constants(pipeline, cmd, &element_count, size_of(u32))
		push_descriptors_bind_buffer(&push, 0, 0, u32(slot), in_device.buffer, 0, size)
		push_descriptors_bind_buffer(&push, 0, 1, u32(slot), out_device.buffer, 0, size)
		push_descriptors_flush(&push, cmd, pipeline.layout, u32(slot))

		for _ in 0 ..< iterations {
			vulkan.CmdDispatch(cmd, groups, 1, 1)
			// The next dispatch overwrites what this one wrote.
			buffer_barrier(cmd, out_device.buffer, 0, size, {.COMPUTE_SHADER}, {.COMPUTE_SHADER}, {.SHADER_STORAGE_WRITE}, {.SHADER_STORAGE_WRITE})
		}

		if use_timestamps {timestamps_write(&timestamps, cmd, 1)}

		buffer_barrier(cmd, out_device.buffer, 0, size, {.COMPUTE_SHADER}, {.TRANSFER}, {.SHADER_STORAGE_WRITE}, {.TRANSFER_READ})
		gpu_copy_buffer(self.gpu, out_device.buffer, out_host.buffer, size, cmd)
		buffer_barrier(cmd, out_host.buffer, 0, size, {.TRANSFER}, {.HOST}, {.TRANSFER_WRITE}, {.HOST_READ})

		start := time.tick_now()
		value := compute_submit(self, slot)
		compute_wait(self, value)
		append(&roundtrips, time.duration_milliseconds(time.tick_diff(start, time.tick_now())))

		if use_timestamps {
			ticks: [2]u64
			if timestamps_read(&timestamps, 0, 2, ticks[:]) {
				append(
					&gpu_times,
					f64(ticks[1] - ticks[0]) * f64(info.timestamp_period_ns) / (1e6 * f64(iterations)),
				)
			}
		}

		output := cast([^]f32)out_host.mapped
		for i in 0 ..< elements {
			if output[i] != f32(i % 512) * 2.0 + 1.0 {verified = false; break}
		}
	}

	return Compute_Probe {
			elements = elements,
			iterations = iterations,
			samples = samples,
			gpu_ms_per_iteration = _median(gpu_times[:]),
			gpu_time_available = use_timestamps && len(gpu_times) > 0,
			roundtrip_ms = _median(roundtrips[:]),
			verified = verified,
		},
		true
}

@(private)
_median :: proc(values: []f64) -> f64 {
	if len(values) == 0 {return 0}
	slice.sort(values)
	return values[len(values) / 2]
}

// compute_begin waits for the chosen slot's previous submission and opens its
// command buffer. Re-recording is only valid once that submission completed.
@(private)
compute_begin :: proc(self: ^Compute) -> (cmd: vulkan.CommandBuffer, slot: int) {
	slot = int(self.next_slot)
	self.next_slot = (self.next_slot + 1) % COMPUTE_SLOTS
	s := &self.slots[slot]
	timeline_wait(&self.timeline, s.value)
	vk_assert(vulkan.ResetCommandBuffer(s.cmd, {}), "vkResetCommandBuffer")
	vk_assert(
		vulkan.BeginCommandBuffer(s.cmd, &vulkan.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO}),
		"vkBeginCommandBuffer",
	)
	return s.cmd, slot
}

// compute_submit closes and submits the slot, returning the timeline value that
// signals its completion.
@(private)
compute_submit :: proc(self: ^Compute, slot: int) -> u64 {
	s := &self.slots[slot]
	vk_assert(vulkan.EndCommandBuffer(s.cmd), "vkEndCommandBuffer")

	value := timeline_next(&self.timeline)
	cmd_info := vulkan.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = s.cmd,
	}
	signal_info := vulkan.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = self.timeline.semaphore,
		value     = value,
		stageMask = {.ALL_COMMANDS},
	}
	submit_info := vulkan.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos  = &signal_info,
	}
	vk_assert(vulkan.QueueSubmit2(self.gpu.compute_queue, 1, &submit_info, 0), "vkQueueSubmit2(compute)")
	s.value = value
	return value
}

@(private)
compute_wait :: proc(self: ^Compute, value: u64) {
	timeline_wait(&self.timeline, value)
}
