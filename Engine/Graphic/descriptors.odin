package graphic

import "core:log"
import "vendor:vulkan"

// Per-frame camera uniforms. Bound through push descriptors (core in Vulkan 1.4,
// maintenance6's vkCmdPushDescriptorSet2), which removes the need for a
// descriptor pool and long-lived descriptor sets entirely.
@(private)
Uniforms :: struct {
	gpu:     ^GPU,
	buffers: [dynamic]Buffer,
}

@(private)
uniforms_init :: proc(gpu: ^GPU) -> (result: Uniforms, ok: bool) {
	log.debugf("[VULKAN] Uniforms initialization...")
	tmp := Uniforms{gpu = gpu}
	committed := false
	defer if !committed {uniforms_destroy(&tmp)}

	tmp.buffers = make([dynamic]Buffer, MAX_FRAMES_IN_FLIGHT)
	buffer_size := vulkan.DeviceSize(size_of(UniformBufferObject))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		tmp.buffers[i] = buffer_init(gpu, buffer_size, {.UNIFORM_BUFFER}, .HostVisible) or_return
	}
	log.debugf("[VULKAN]   Uniforms ready (%d frames in flight)", MAX_FRAMES_IN_FLIGHT)
	committed = true
	return tmp, true
}

@(private)
uniforms_destroy :: proc(self: ^Uniforms) {
	if self.gpu == nil {return}
	log.debugf("[VULKAN] Destroying Uniforms...")
	for &buffer in self.buffers {buffer_destroy(&buffer)}
	delete(self.buffers); self.buffers = nil
	log.debugf("[VULKAN]   Uniforms destroyed")
}

@(private)
uniforms_write :: proc(self: ^Uniforms, ubo: UniformBufferObject, frame: u32) {
	assert(frame < u32(len(self.buffers)), "uniform frame index out of range")
	mut := ubo
	buffer_write(&self.buffers[frame], &mut, size_of(UniformBufferObject), 0)
}

@(private)
uniforms_push :: proc(self: ^Uniforms, cmd: vulkan.CommandBuffer, layout: vulkan.PipelineLayout, frame: u32) {
	assert(frame < u32(len(self.buffers)), "uniform frame index out of range")
	buffer_info := vulkan.DescriptorBufferInfo{buffer = self.buffers[frame].buffer, offset = 0, range = size_of(UniformBufferObject)}
	write := vulkan.WriteDescriptorSet{
		sType = .WRITE_DESCRIPTOR_SET,
		dstBinding = 0,
		dstArrayElement = 0,
		descriptorType = .UNIFORM_BUFFER,
		descriptorCount = 1,
		pBufferInfo = &buffer_info,
	}
	info := vulkan.PushDescriptorSetInfo{
		sType = .PUSH_DESCRIPTOR_SET_INFO,
		stageFlags = {.VERTEX},
		layout = layout,
		set = 0,
		descriptorWriteCount = 1,
		pDescriptorWrites = &write,
	}
	vulkan.CmdPushDescriptorSet2(cmd, &info)
}
