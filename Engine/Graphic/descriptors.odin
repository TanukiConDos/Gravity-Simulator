package graphic

import "core:log"
import "vendor:vulkan"

DescriptorPool :: struct {
	gpu:          ^GPU,
	pool:         vulkan.DescriptorPool,
	sets:         [dynamic]vulkan.DescriptorSet,
	uniform_bufs: [dynamic]Buffer,
}

descriptor_pool_create :: proc(gpu: ^GPU, pipeline: ^Pipeline) -> (self: DescriptorPool, ok: bool) {
	self.gpu = gpu
	log.debugf("[VULKAN] DescriptorPool initialization...")
	_dp_create_pool(&self)
	_dp_create_uniform_buffers(&self)
	_dp_create_sets(&self, pipeline)
	log.debugf("[VULKAN]   DescriptorPool ready (%d frames in flight)", MAX_FRAMES_IN_FLIGHT)
	return self, true
}

descriptor_pool_destroy :: proc(self: ^DescriptorPool) {
	log.debugf("[VULKAN] Destroying DescriptorPool...")
	if self.gpu != nil {
		if self.pool != 0 {vulkan.DestroyDescriptorPool(self.gpu.device, self.pool, nil)}
		for &buffer in self.uniform_bufs {buffer_destroy(&buffer)}
	}
	delete(self.sets); delete(self.uniform_bufs)
	log.debugf("[VULKAN]   DescriptorPool destroyed")
}

descriptor_pool_update_ubo :: proc(self: ^DescriptorPool, ubo: UniformBufferObject, current_frame: u32) {
	mut := ubo
	mut.proj[1, 1] *= -1
	buffer_write(&self.uniform_bufs[current_frame], &mut, size_of(UniformBufferObject), 0)
}

@(private) _dp_create_pool :: proc(self: ^DescriptorPool) {
	pool_size := vulkan.DescriptorPoolSize{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT}
	pool_info := vulkan.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, poolSizeCount = 1, pPoolSizes = &pool_size, maxSets = MAX_FRAMES_IN_FLIGHT}
	vulkan.CreateDescriptorPool(self.gpu.device, &pool_info, nil, &self.pool)
}

@(private) _dp_create_uniform_buffers :: proc(self: ^DescriptorPool) {
	buffer_size := vulkan.DeviceSize(size_of(UniformBufferObject))
	self.uniform_bufs = make([dynamic]Buffer, MAX_FRAMES_IN_FLIGHT)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer, _ := buffer_create(self.gpu, buffer_size, {.UNIFORM_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		self.uniform_bufs[i] = buffer
		buffer_map(&self.uniform_bufs[i])
	}
}

@(private) _dp_create_sets :: proc(self: ^DescriptorPool, pipeline: ^Pipeline) {
	total := int(MAX_FRAMES_IN_FLIGHT)
	layouts := make([dynamic]vulkan.DescriptorSetLayout, total); defer delete(layouts)
	for i in 0 ..< total {layouts[i] = pipeline.descriptor_set_layout}
	allocate_info := vulkan.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = self.pool, descriptorSetCount = u32(total), pSetLayouts = raw_data(layouts)}
	self.sets = make([dynamic]vulkan.DescriptorSet, total); vulkan.AllocateDescriptorSets(self.gpu.device, &allocate_info, raw_data(self.sets))
	for i: u32 = 0; i < MAX_FRAMES_IN_FLIGHT; i += 1 {
		buffer_info := vulkan.DescriptorBufferInfo{buffer = self.uniform_bufs[i].buffer, offset = 0, range = size_of(UniformBufferObject)}
		write_desc := vulkan.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = self.sets[i], dstBinding = 0, dstArrayElement = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, pBufferInfo = &buffer_info}
		vulkan.UpdateDescriptorSets(self.gpu.device, 1, &write_desc, 0, nil)
	}
}
