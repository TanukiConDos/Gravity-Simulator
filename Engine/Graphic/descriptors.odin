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

descriptor_pool_create :: proc(gpu: ^GPU, pipeline: ^Pipeline, num_objects: u32) -> (d: DescriptorPool, ok: bool) {
	if num_objects == 0 {return d, true}
	d.gpu = gpu; d.num_objects = num_objects
	log.debugf("[VULKAN] DescriptorPool initialization (%d objects)...", num_objects)
	_dp_create_pool(&d)
	_dp_create_uniform_buffers(&d, gpu)
	_dp_create_sets(&d, pipeline, gpu)
	log.debugf("[VULKAN]   DescriptorPool ready")
	return d, true
}

descriptor_pool_destroy :: proc(d: ^DescriptorPool) {
	log.debugf("[VULKAN] Destroying DescriptorPool...")
	if d.gpu != nil {
		if d.pool != 0 {vulkan.DestroyDescriptorPool(d.gpu.device, d.pool, nil)}
		for &buf in d.uniform_bufs {buffer_destroy(&buf)}
	}
	delete(d.sets); delete(d.uniform_bufs)
	log.debugf("[VULKAN]   DescriptorPool destroyed")
}

descriptor_pool_get_set :: proc(d: ^DescriptorPool, cf, idx: u32) -> vulkan.DescriptorSet {
	return d.sets[cf * d.num_objects + idx]
}

descriptor_pool_update_ubo :: proc(d: ^DescriptorPool, ubo: UniformBufferObject, ci, idx: u32) {
	mut := ubo
	mut.proj[1, 1] *= -1
	buffer_write(&d.uniform_bufs[ci], &mut, size_of(UniformBufferObject), vulkan.DeviceSize(size_of(UniformBufferObject)) * vulkan.DeviceSize(idx))
}

descriptor_pool_flush_all :: proc(d: ^DescriptorPool) {
	for i in 0 ..< len(d.uniform_bufs) {
		buffer_flush(&d.uniform_bufs[i])
	}
}

@(private) _dp_create_pool :: proc(d: ^DescriptorPool) {
	ps := vulkan.DescriptorPoolSize{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT * d.num_objects}
	pi := vulkan.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, poolSizeCount = 1, pPoolSizes = &ps, maxSets = MAX_FRAMES_IN_FLIGHT * d.num_objects}
	vulkan.CreateDescriptorPool(d.gpu.device, &pi, nil, &d.pool)
}

@(private) _dp_create_uniform_buffers :: proc(d: ^DescriptorPool, gpu: ^GPU) {
	bs := vulkan.DeviceSize(size_of(UniformBufferObject) * vulkan.DeviceSize(d.num_objects))
	d.uniform_bufs = make([dynamic]Buffer, MAX_FRAMES_IN_FLIGHT)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buf, _ := buffer_create(d.gpu, bs, {.UNIFORM_BUFFER}, {.HOST_VISIBLE})
		d.uniform_bufs[i] = buf
		buffer_map(&d.uniform_bufs[i])
	}
}

@(private) _dp_create_sets :: proc(d: ^DescriptorPool, pipeline: ^Pipeline, gpu: ^GPU) {
	total := int(MAX_FRAMES_IN_FLIGHT * d.num_objects)
	layouts := make([dynamic]vulkan.DescriptorSetLayout, total); defer delete(layouts)
	for i in 0 ..< total {layouts[i] = pipeline.descriptor_set_layout}
	ai := vulkan.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = d.pool, descriptorSetCount = u32(total), pSetLayouts = raw_data(layouts)}
	d.sets = make([dynamic]vulkan.DescriptorSet, total); vulkan.AllocateDescriptorSets(d.gpu.device, &ai, raw_data(d.sets))
	for i: u32 = 0; i < MAX_FRAMES_IN_FLIGHT; i += 1 {
		for j: u32 = 0; j < d.num_objects; j += 1 {
			bi := vulkan.DescriptorBufferInfo{buffer = d.uniform_bufs[i].buffer, offset = vulkan.DeviceSize(size_of(UniformBufferObject)) * vulkan.DeviceSize(j), range = size_of(UniformBufferObject)}
			w := vulkan.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = d.sets[i * d.num_objects + j], dstBinding = 0, dstArrayElement = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, pBufferInfo = &bi}
			vulkan.UpdateDescriptorSets(d.gpu.device, 1, &w, 0, nil)
		}
	}
}
