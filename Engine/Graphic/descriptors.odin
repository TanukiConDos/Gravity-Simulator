package graphic

import "core:log"
import "vendor:vulkan"

DescriptorPool :: struct {
	gpu:         ^GPU,
	pool:        vulkan.DescriptorPool,
	sets:        [dynamic]vulkan.DescriptorSet,
	uniform_bufs: [dynamic]Buffer,
	num_objects: u32,
}

descriptor_pool_create :: proc(gpu: ^GPU, pipeline: ^Pipeline, num_objects: u32) -> (self: DescriptorPool, ok: bool) {
	if num_objects == 0 {return self, true}
	self.gpu = gpu; self.num_objects = num_objects
	log.debugf("[VULKAN] DescriptorPool initialization (%d objects)...", num_objects)
	_dp_create_pool(&self)
	_dp_create_uniform_buffers(&self, gpu)
	_dp_create_sets(&self, pipeline, gpu)
	log.debugf("[VULKAN]   DescriptorPool ready")
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

descriptor_pool_get_set :: proc(self: ^DescriptorPool, current_frame, index: u32) -> vulkan.DescriptorSet {
	return self.sets[current_frame * self.num_objects + index]
}

descriptor_pool_update_ubo :: proc(self: ^DescriptorPool, ubo: UniformBufferObject, current_frame_index, index: u32) {
	mut := ubo
	mut.proj[1, 1] *= -1
	buffer_write(&self.uniform_bufs[current_frame_index], &mut, size_of(UniformBufferObject), vulkan.DeviceSize(size_of(UniformBufferObject)) * vulkan.DeviceSize(index))
}

descriptor_pool_flush_all :: proc(self: ^DescriptorPool) {
	for i in 0 ..< len(self.uniform_bufs) {
		buffer_flush(&self.uniform_bufs[i])
	}
}

@(private) _dp_create_pool :: proc(self: ^DescriptorPool) {
	pool_size := vulkan.DescriptorPoolSize{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT * self.num_objects}
	pool_info := vulkan.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, poolSizeCount = 1, pPoolSizes = &pool_size, maxSets = MAX_FRAMES_IN_FLIGHT * self.num_objects}
	vulkan.CreateDescriptorPool(self.gpu.device, &pool_info, nil, &self.pool)
}

@(private) _dp_create_uniform_buffers :: proc(self: ^DescriptorPool, gpu: ^GPU) {
	buffer_size := vulkan.DeviceSize(size_of(UniformBufferObject) * vulkan.DeviceSize(self.num_objects))
	self.uniform_bufs = make([dynamic]Buffer, MAX_FRAMES_IN_FLIGHT)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer, _ := buffer_create(self.gpu, buffer_size, {.UNIFORM_BUFFER}, {.HOST_VISIBLE})
		self.uniform_bufs[i] = buffer
		buffer_map(&self.uniform_bufs[i])
	}
}

@(private) _dp_create_sets :: proc(self: ^DescriptorPool, pipeline: ^Pipeline, gpu: ^GPU) {
	total := int(MAX_FRAMES_IN_FLIGHT * self.num_objects)
	layouts := make([dynamic]vulkan.DescriptorSetLayout, total); defer delete(layouts)
	for i in 0 ..< total {layouts[i] = pipeline.descriptor_set_layout}
	allocate_info := vulkan.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = self.pool, descriptorSetCount = u32(total), pSetLayouts = raw_data(layouts)}
	self.sets = make([dynamic]vulkan.DescriptorSet, total); vulkan.AllocateDescriptorSets(self.gpu.device, &allocate_info, raw_data(self.sets))
	for i: u32 = 0; i < MAX_FRAMES_IN_FLIGHT; i += 1 {
		for j: u32 = 0; j < self.num_objects; j += 1 {
			buffer_info := vulkan.DescriptorBufferInfo{buffer = self.uniform_bufs[i].buffer, offset = vulkan.DeviceSize(size_of(UniformBufferObject)) * vulkan.DeviceSize(j), range = size_of(UniformBufferObject)}
			write_desc := vulkan.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = self.sets[i * self.num_objects + j], dstBinding = 0, dstArrayElement = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, pBufferInfo = &buffer_info}
			vulkan.UpdateDescriptorSets(self.gpu.device, 1, &write_desc, 0, nil)
		}
	}
}
