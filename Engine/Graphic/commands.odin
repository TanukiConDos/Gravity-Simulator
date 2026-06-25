package graphic

import "base:intrinsics"
import "core:log"
import "vendor:vulkan"

CommandPool :: struct {gpu: ^GPU, pool: vulkan.CommandPool, command_buffers: [dynamic]vulkan.CommandBuffer}

command_pool_create :: proc(gpu: ^GPU) -> (cp: CommandPool, ok: bool) {
	log.debugf("[VULKAN] CommandPool initialization..."); cp.gpu = gpu
	pi := vulkan.CommandPoolCreateInfo{sType=.COMMAND_POOL_CREATE_INFO,queueFamilyIndex=gpu_get_queue_family(gpu),flags={.RESET_COMMAND_BUFFER}}
	if vulkan.CreateCommandPool(gpu.device, &pi, nil, &cp.pool) != .SUCCESS {return {}, false}
	cp.command_buffers = make([dynamic]vulkan.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
	ai := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=cp.pool,level=.PRIMARY,commandBufferCount=MAX_FRAMES_IN_FLIGHT}
	vulkan.AllocateCommandBuffers(gpu.device, &ai, raw_data(cp.command_buffers))
	log.debugf("[VULKAN]   CommandPool ready (%d command buffers)", len(cp.command_buffers))
	return cp, true
}

command_pool_destroy :: proc(cp: ^CommandPool) {log.debugf("[VULKAN] Destroying CommandPool..."); vulkan.DestroyCommandPool(cp.gpu.device, cp.pool, nil); delete(cp.command_buffers); log.debugf("[VULKAN]   CommandPool destroyed")}
command_pool_reset :: proc(cp: ^CommandPool, frame: u32) {vulkan.ResetCommandBuffer(cp.command_buffers[frame], {})}
command_pool_begin :: proc(cp: ^CommandPool, frame: u32) -> vulkan.CommandBuffer {cmd:=cp.command_buffers[frame]; vulkan.BeginCommandBuffer(cmd, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO}); return cmd}
command_pool_end :: proc(cp: ^CommandPool, cmd: vulkan.CommandBuffer) {vulkan.EndCommandBuffer(cmd)}

command_pool_begin_one_shot :: proc(cp: ^CommandPool) -> vulkan.CommandBuffer {
	ai := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=cp.pool,level=.PRIMARY,commandBufferCount=1}
	cmd: vulkan.CommandBuffer; vulkan.AllocateCommandBuffers(cp.gpu.device, &ai, &cmd)
	vulkan.BeginCommandBuffer(cmd, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}})
	return cmd
}

command_pool_end_one_shot :: proc(cp: ^CommandPool, cmd_buf: vulkan.CommandBuffer) {
	vulkan.EndCommandBuffer(cmd_buf)
	cmd := cmd_buf
	si := vulkan.SubmitInfo{sType=.SUBMIT_INFO,commandBufferCount=1,pCommandBuffers=&cmd}
	vulkan.QueueSubmit(cp.gpu.graphics_queue, 1, &si, 0); vulkan.QueueWaitIdle(cp.gpu.graphics_queue)
	vulkan.FreeCommandBuffers(cp.gpu.device, cp.pool, 1, &cmd)
}

Buffer :: struct {gpu: ^GPU, buffer: vulkan.Buffer, memory: vulkan.DeviceMemory, size: vulkan.DeviceSize, mapped: rawptr, memory_range: vulkan.MappedMemoryRange}

buffer_create :: proc(gpu: ^GPU, size: vulkan.DeviceSize, usage: vulkan.BufferUsageFlags, props: vulkan.MemoryPropertyFlags) -> (b: Buffer, ok: bool) {
	b.gpu = gpu; b.size = size; b.buffer, b.memory, ok = gpu_create_buffer(gpu, size, usage, props); return
}

buffer_destroy :: proc(b: ^Buffer) {
	if b.mapped != nil {vulkan.UnmapMemory(b.gpu.device, b.memory)}
	if b.buffer != 0 {vulkan.DestroyBuffer(b.gpu.device, b.buffer, nil)}
	if b.memory != 0 {vulkan.FreeMemory(b.gpu.device, b.memory, nil)}
}

buffer_map :: proc(b: ^Buffer) -> bool {return vulkan.MapMemory(b.gpu.device, b.memory, 0, b.size, {}, &b.mapped)==.SUCCESS}

buffer_write :: proc(b: ^Buffer, data: rawptr, size, offset: vulkan.DeviceSize) {
	if offset+size <= b.size {
		intrinsics.mem_copy(rawptr(uintptr(b.mapped)+uintptr(offset)), data, int(size))
		b.memory_range = vulkan.MappedMemoryRange{sType=.MAPPED_MEMORY_RANGE,memory=b.memory,offset=offset,size=size}
	}
}

buffer_flush :: proc(b: ^Buffer) {
	if b.mapped != nil {
		range := vulkan.MappedMemoryRange{
			sType  = .MAPPED_MEMORY_RANGE,
			memory = b.memory,
			size   = vulkan.DeviceSize(vulkan.WHOLE_SIZE),
			offset = 0,
		}
		vulkan.FlushMappedMemoryRanges(b.gpu.device, 1, &range)
	}
}
