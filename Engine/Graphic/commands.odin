package graphic

import "base:intrinsics"
import "core:log"
import "vendor:vulkan"

CommandPool :: struct {gpu: ^GPU, pool: vulkan.CommandPool, command_buffers: [dynamic]vulkan.CommandBuffer}

command_pool_create :: proc(gpu: ^GPU) -> (command_pool: CommandPool, ok: bool) {
	log.debugf("[VULKAN] CommandPool initialization..."); command_pool.gpu = gpu
	pool_info := vulkan.CommandPoolCreateInfo{sType=.COMMAND_POOL_CREATE_INFO,queueFamilyIndex=gpu_get_queue_family(gpu),flags={.RESET_COMMAND_BUFFER}}
	if vulkan.CreateCommandPool(gpu.device, &pool_info, nil, &command_pool.pool) != .SUCCESS {return {}, false}
	command_pool.command_buffers = make([dynamic]vulkan.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
	allocate_info := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=command_pool.pool,level=.PRIMARY,commandBufferCount=MAX_FRAMES_IN_FLIGHT}
	vulkan.AllocateCommandBuffers(gpu.device, &allocate_info, raw_data(command_pool.command_buffers))
	log.debugf("[VULKAN]   CommandPool ready (%d command buffers)", len(command_pool.command_buffers))
	return command_pool, true
}

command_pool_destroy :: proc(command_pool: ^CommandPool) {log.debugf("[VULKAN] Destroying CommandPool..."); vulkan.DeviceWaitIdle(command_pool.gpu.device); vulkan.DestroyCommandPool(command_pool.gpu.device, command_pool.pool, nil); delete(command_pool.command_buffers); log.debugf("[VULKAN]   CommandPool destroyed")}
command_pool_reset :: proc(command_pool: ^CommandPool, frame: u32) {vulkan.ResetCommandBuffer(command_pool.command_buffers[frame], {})}
command_pool_begin :: proc(command_pool: ^CommandPool, frame: u32) -> vulkan.CommandBuffer {command_buffer:=command_pool.command_buffers[frame]; vulkan.BeginCommandBuffer(command_buffer, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO}); return command_buffer}
command_pool_end :: proc(command_pool: ^CommandPool, cmd: vulkan.CommandBuffer) {vulkan.EndCommandBuffer(cmd)}

command_pool_begin_one_shot :: proc(command_pool: ^CommandPool) -> vulkan.CommandBuffer {
	allocate_info := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=command_pool.pool,level=.PRIMARY,commandBufferCount=1}
	command_buffer: vulkan.CommandBuffer; vulkan.AllocateCommandBuffers(command_pool.gpu.device, &allocate_info, &command_buffer)
	vulkan.BeginCommandBuffer(command_buffer, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}})
	return command_buffer
}

command_pool_end_one_shot :: proc(command_pool: ^CommandPool, cmd_buf: vulkan.CommandBuffer) {
	vulkan.EndCommandBuffer(cmd_buf)
	command_buffer := cmd_buf
	submit_info := vulkan.SubmitInfo{sType=.SUBMIT_INFO,commandBufferCount=1,pCommandBuffers=&command_buffer}
	vulkan.QueueSubmit(command_pool.gpu.graphics_queue, 1, &submit_info, 0); vulkan.QueueWaitIdle(command_pool.gpu.graphics_queue)
	vulkan.FreeCommandBuffers(command_pool.gpu.device, command_pool.pool, 1, &command_buffer)
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

buffer_write :: proc(buffer: ^Buffer, data: rawptr, size, offset: vulkan.DeviceSize) {
	if offset+size <= buffer.size {
		intrinsics.mem_copy(rawptr(uintptr(buffer.mapped)+uintptr(offset)), data, int(size))
		buffer.memory_range = vulkan.MappedMemoryRange{sType=.MAPPED_MEMORY_RANGE,memory=buffer.memory,offset=offset,size=size}
	}
}

buffer_flush :: proc(buffer: ^Buffer) {
	if buffer.mapped != nil {
		range := vulkan.MappedMemoryRange{
			sType  = .MAPPED_MEMORY_RANGE,
			memory = buffer.memory,
			size   = vulkan.DeviceSize(vulkan.WHOLE_SIZE),
			offset = 0,
		}
		vulkan.FlushMappedMemoryRanges(buffer.gpu.device, 1, &range)
	}
}
