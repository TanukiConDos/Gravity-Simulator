package graphic

import "base:intrinsics"
import "core:log"
import "vendor:vulkan"

@(private)
CommandPool :: struct {gpu: ^GPU, pool: vulkan.CommandPool, command_buffers: [dynamic]vulkan.CommandBuffer}

@(private)
command_pool_init :: proc(gpu: ^GPU) -> (result: CommandPool, ok: bool) {
	log.debugf("[VULKAN] CommandPool initialization...")
	tmp := CommandPool{gpu = gpu}
	pool_info := vulkan.CommandPoolCreateInfo{sType=.COMMAND_POOL_CREATE_INFO,queueFamilyIndex=gpu.graphics_queue_family_index,flags={.RESET_COMMAND_BUFFER}}
	vk_check(vulkan.CreateCommandPool(gpu.device, &pool_info, nil, &tmp.pool), "vkCreateCommandPool") or_return
	tmp.command_buffers = make([dynamic]vulkan.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
	allocate_info := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=tmp.pool,level=.PRIMARY,commandBufferCount=MAX_FRAMES_IN_FLIGHT}
	vk_assert(vulkan.AllocateCommandBuffers(gpu.device, &allocate_info, raw_data(tmp.command_buffers)), "vkAllocateCommandBuffers")
	log.debugf("[VULKAN]   CommandPool ready (%d command buffers)", len(tmp.command_buffers))
	return tmp, true
}

@(private)
command_pool_destroy :: proc(self: ^CommandPool) {
	if self.gpu == nil || self.pool == 0 {return}
	log.debugf("[VULKAN] Destroying CommandPool...")
	vk_assert(vulkan.DeviceWaitIdle(self.gpu.device), "vkDeviceWaitIdle")
	vulkan.DestroyCommandPool(self.gpu.device, self.pool, nil)
	self.pool = 0
	delete(self.command_buffers); self.command_buffers = nil
	log.debugf("[VULKAN]   CommandPool destroyed")
}

@(private) command_pool_reset :: proc(command_pool: ^CommandPool, frame: u32) {vk_assert(vulkan.ResetCommandBuffer(command_pool.command_buffers[frame], {}), "vkResetCommandBuffer")}
@(private) command_pool_begin :: proc(command_pool: ^CommandPool, frame: u32) -> vulkan.CommandBuffer {command_buffer:=command_pool.command_buffers[frame]; vk_assert(vulkan.BeginCommandBuffer(command_buffer, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO}), "vkBeginCommandBuffer"); return command_buffer}
@(private) command_pool_end :: proc(command_pool: ^CommandPool, cmd: vulkan.CommandBuffer) {vk_assert(vulkan.EndCommandBuffer(cmd), "vkEndCommandBuffer")}

// Allocates a standalone primary buffer owned by the pool; the pool reclaims it
// on destroy unless the caller frees it earlier.
@(private)
command_pool_allocate :: proc(command_pool: ^CommandPool) -> vulkan.CommandBuffer {
	allocate_info := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=command_pool.pool,level=.PRIMARY,commandBufferCount=1}
	command_buffer: vulkan.CommandBuffer
	vk_assert(vulkan.AllocateCommandBuffers(command_pool.gpu.device, &allocate_info, &command_buffer), "vkAllocateCommandBuffers")
	return command_buffer
}

@(private) command_buffer_reset :: proc(cmd: vulkan.CommandBuffer) {vk_assert(vulkan.ResetCommandBuffer(cmd, {}), "vkResetCommandBuffer")}
@(private) command_buffer_begin :: proc(cmd: vulkan.CommandBuffer) -> vulkan.CommandBuffer {vk_assert(vulkan.BeginCommandBuffer(cmd, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO}), "vkBeginCommandBuffer"); return cmd}
@(private) command_buffer_end :: proc(cmd: vulkan.CommandBuffer) {vk_assert(vulkan.EndCommandBuffer(cmd), "vkEndCommandBuffer")}

@(private)
command_pool_begin_one_shot :: proc(command_pool: ^CommandPool) -> vulkan.CommandBuffer {
	allocate_info := vulkan.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=command_pool.pool,level=.PRIMARY,commandBufferCount=1}
	command_buffer: vulkan.CommandBuffer; vk_assert(vulkan.AllocateCommandBuffers(command_pool.gpu.device, &allocate_info, &command_buffer), "vkAllocateCommandBuffers")
	vk_assert(vulkan.BeginCommandBuffer(command_buffer, &vulkan.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}}), "vkBeginCommandBuffer")
	return command_buffer
}

@(private)
command_pool_end_one_shot :: proc(command_pool: ^CommandPool, cmd_buf: vulkan.CommandBuffer) {
	vk_assert(vulkan.EndCommandBuffer(cmd_buf), "vkEndCommandBuffer")
	command_buffer := cmd_buf
	submit_info := vulkan.SubmitInfo{sType=.SUBMIT_INFO,commandBufferCount=1,pCommandBuffers=&command_buffer}
	vk_assert(vulkan.QueueSubmit(command_pool.gpu.graphics_queue, 1, &submit_info, 0), "vkQueueSubmit")
	vk_assert(vulkan.QueueWaitIdle(command_pool.gpu.graphics_queue), "vkQueueWaitIdle")
	vulkan.FreeCommandBuffers(command_pool.gpu.device, command_pool.pool, 1, &command_buffer)
}

// A GPU buffer suballocated from the engine's memory blocks. Host-visible
// buffers stay persistently mapped (HOST_COHERENT memory, no flushing).
@(private)
Buffer :: struct {
	gpu:    ^GPU,
	buffer: vulkan.Buffer,
	mem:    MemAlloc,
	size:   vulkan.DeviceSize,
	mapped: rawptr,
}

@(private)
buffer_init :: proc(gpu: ^GPU, size: vulkan.DeviceSize, usage: vulkan.BufferUsageFlags, kind: MemoryKind) -> (result: Buffer, ok: bool) {
	tmp := Buffer{gpu = gpu, size = size}
	buf_info := vulkan.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = size, usage = usage, sharingMode = .EXCLUSIVE}
	vk_check(vulkan.CreateBuffer(gpu.device, &buf_info, nil, &tmp.buffer), "vkCreateBuffer") or_return
	mem_reqs: vulkan.MemoryRequirements
	vulkan.GetBufferMemoryRequirements(gpu.device, tmp.buffer, &mem_reqs)
	mem, allocated := allocator_alloc(&gpu.allocator, mem_reqs, kind)
	if !allocated {
		vulkan.DestroyBuffer(gpu.device, tmp.buffer, nil)
		return {}, false
	}
	tmp.mem = mem
	vk_assert(vulkan.BindBufferMemory(gpu.device, tmp.buffer, mem_alloc_memory(mem), mem_alloc_offset(mem)), "vkBindBufferMemory")
	if kind == .HostVisible {tmp.mapped = mem_alloc_mapped(mem)}
	return tmp, true
}

@(private)
buffer_destroy :: proc(self: ^Buffer) {
	if self.gpu == nil {return}
	if self.buffer != 0 {vulkan.DestroyBuffer(self.gpu.device, self.buffer, nil); self.buffer = 0}
	if self.mem.block != nil {allocator_free(&self.gpu.allocator, self.mem); self.mem = {}}
	self.mapped = nil
}

// No Vulkan call here, so violations are programming errors; both checks are
// O(1) and never run per element.
@(private)
buffer_write :: proc(buffer: ^Buffer, data: rawptr, size, offset: vulkan.DeviceSize) {
	assert(buffer.mapped != nil, "buffer_write on an unmapped buffer")
	assert(offset + size <= buffer.size, "buffer_write out of bounds")
	intrinsics.mem_copy(rawptr(uintptr(buffer.mapped) + uintptr(offset)), data, int(size))
}
