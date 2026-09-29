package graphic

import "core:log"
import "vendor:vulkan"

// GPU synchronization primitives shared by the compute context: a timeline
// semaphore, buffer memory barriers and timestamp queries.

// Timeline semaphore: a monotonic 64-bit counter signaled by queue submissions
// and waitable on both sides — the host with vkWaitSemaphores, the device with
// SemaphoreSubmitInfo.value. One context owns one timeline; the submitting
// thread advances it and consumers wait on a specific value.
@(private)
Timeline :: struct {
	device:    vulkan.Device,
	semaphore: vulkan.Semaphore,
	value:     u64,
}

@(private)
timeline_init :: proc(gpu: ^GPU) -> (Timeline, bool) {
	create_info := vulkan.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &vulkan.SemaphoreTypeCreateInfo {
			sType         = .SEMAPHORE_TYPE_CREATE_INFO,
			semaphoreType = .TIMELINE,
			initialValue  = 0,
		},
	}
	semaphore: vulkan.Semaphore
	if !vk_check(
		vulkan.CreateSemaphore(gpu.device, &create_info, nil, &semaphore),
		"vkCreateSemaphore(timeline)",
	) {
		return {}, false
	}
	return Timeline{device = gpu.device, semaphore = semaphore}, true
}

@(private)
timeline_destroy :: proc(self: ^Timeline) {
	if self.device == nil || self.semaphore == 0 {return}
	vulkan.DestroySemaphore(self.device, self.semaphore, nil)
	self^ = {}
}

// timeline_next reserves the next value. Only the submitting thread calls it.
@(private)
timeline_next :: proc(self: ^Timeline) -> u64 {
	self.value += 1
	return self.value
}

// timeline_value reads the timeline's current counter without blocking.
@(private)
timeline_value :: proc(self: ^Timeline) -> u64 {
	return semaphore_counter(self.device, self.semaphore)
}

// semaphore_counter reads a timeline semaphore's current value without waiting.
// The render-view vending protocol uses it to tell whether the frame that last
// read a render set has completed. A zero handle means "no timeline" and reads
// as zero.
@(private)
semaphore_counter :: proc(device: vulkan.Device, semaphore: vulkan.Semaphore) -> u64 {
	if semaphore == 0 {return 0}
	value: u64
	vk_assert(
		vulkan.GetSemaphoreCounterValue(device, semaphore, &value),
		"vkGetSemaphoreCounterValue",
	)
	return value
}

// timeline_wait blocks the host until the timeline reaches `value`; a value of
// zero is "nothing signaled yet" and returns immediately. A failure here means
// the device was lost, so it follows the wait-on-fence error path.
@(private)
timeline_wait :: proc(self: ^Timeline, value: u64) {
	if value == 0 {return}
	target := value
	wait_info := vulkan.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &self.semaphore,
		pValues        = &target,
	}
	vk_assert(
		vulkan.WaitSemaphores(self.device, &wait_info, max(u64)),
		"vkWaitSemaphores",
	)
}

// buffer_barrier is the buffer counterpart of image_barrier: every transition
// between a transfer, a dispatch and a host read goes through it.
@(private)
buffer_barrier :: proc(
	cmd: vulkan.CommandBuffer,
	buffer: vulkan.Buffer,
	offset, size: vulkan.DeviceSize,
	src_stage, dst_stage: vulkan.PipelineStageFlags2,
	src_access, dst_access: vulkan.AccessFlags2,
) {
	barrier := vulkan.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask        = src_stage,
		srcAccessMask       = src_access,
		dstStageMask        = dst_stage,
		dstAccessMask       = dst_access,
		srcQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
		buffer              = buffer,
		offset              = offset,
		size                = size,
	}
	dependency := vulkan.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers   = &barrier,
	}
	vulkan.CmdPipelineBarrier2(cmd, &dependency)
}

// Timestamp query pool. Two queries per sample bracket the dispatch loop; the
// results are read after the submission completed, so WAIT never stalls.
@(private)
Timestamps :: struct {
	device: vulkan.Device,
	pool:   vulkan.QueryPool,
	count:  int,
}

@(private)
timestamps_init :: proc(gpu: ^GPU, count: int) -> (Timestamps, bool) {
	query_count := count
	if query_count <= 0 {query_count = 2}
	create_info := vulkan.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = u32(query_count),
	}
	pool: vulkan.QueryPool
	if !vk_check(vulkan.CreateQueryPool(gpu.device, &create_info, nil, &pool), "vkCreateQueryPool") {
		return {}, false
	}
	return Timestamps{device = gpu.device, pool = pool, count = query_count}, true
}

@(private)
timestamps_destroy :: proc(self: ^Timestamps) {
	if self.device == nil || self.pool == 0 {return}
	vulkan.DestroyQueryPool(self.device, self.pool, nil)
	self^ = {}
}

@(private)
timestamps_write :: proc(self: ^Timestamps, cmd: vulkan.CommandBuffer, index: int) {
	assert(index < self.count, "timestamp index out of range")
	vulkan.CmdWriteTimestamp2(cmd, {.ALL_COMMANDS}, self.pool, u32(index))
}

@(private)
timestamps_read :: proc(self: ^Timestamps, first, count: int, out: []u64) -> bool {
	assert(count > 0 && first + count <= self.count, "timestamp range out of bounds")
	if len(out) < count {return false}
	flags: vulkan.QueryResultFlags
	flags += {.WAIT, ._64}
	return vk_check(
		vulkan.GetQueryPoolResults(
			self.device,
			self.pool,
			u32(first),
			u32(count),
			count * size_of(u64),
			raw_data(out),
			size_of(u64),
			flags,
		),
		"vkGetQueryPoolResults",
	)
}
