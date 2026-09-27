package graphic

import "core:log"
import "vendor:vulkan"

// Push descriptor usage declared by the renderer. Each spec owns one host-visible
// buffer per frame in flight; (set, binding) must exist in the pipeline's
// reflected interface and is validated by push_descriptors_validate.
//
// The camera uniform is uploaded per draw through vkCmdPushDescriptorSet2
// (maintenance6, core in Vulkan 1.4), so no descriptor pool or long-lived
// descriptor sets are needed.
@(private)
Push_Binding_Spec :: struct {
	set:        u32,
	binding:    u32,
	descriptor: vulkan.DescriptorType,
	size:       vulkan.DeviceSize,
	// External bindings own no buffer; the caller supplies one per frame with
	// push_descriptors_bind_buffer before flushing. Used by compute pipelines,
	// whose storage buffers live with the solver.
	external:   bool,
}

@(private)
Push_Binding :: struct {
	set:          u32,
	binding:      u32,
	descriptor:   vulkan.DescriptorType,
	stage:        vulkan.ShaderStageFlags,
	size:         vulkan.DeviceSize,
	external:     bool,
	buffers:      [PUSH_DESCRIPTOR_SLOTS]Buffer,
	buffer_infos: [PUSH_DESCRIPTOR_SLOTS]vulkan.DescriptorBufferInfo,
	writes:       [PUSH_DESCRIPTOR_SLOTS]vulkan.WriteDescriptorSet,
	bound:        [PUSH_DESCRIPTOR_SLOTS]bool,
}

@(private)
Push_Descriptors :: struct {
	gpu:      ^GPU,
	bindings: [dynamic]Push_Binding,
}

@(private)
push_descriptors_init :: proc(
	gpu: ^GPU,
	specs: []Push_Binding_Spec,
) -> (
	result: Push_Descriptors,
	ok: bool,
) {
	log.debugf("[VULKAN] Push descriptors initialization...")
	tmp := Push_Descriptors{gpu = gpu}
	committed := false
	defer if !committed {push_descriptors_destroy(&tmp)}

	tmp.bindings = make([dynamic]Push_Binding, 0, len(specs))
	for spec in specs {
		append(&tmp.bindings, Push_Binding{
			set        = spec.set,
			binding    = spec.binding,
			descriptor = spec.descriptor,
			size       = spec.size,
			external   = spec.external,
		})

		binding := &tmp.bindings[len(tmp.bindings) - 1]
		// Every slot (render frames and compute submissions) needs a write
		// descriptor, because external bindings are flushed from any slot.
		for frame in 0 ..< PUSH_DESCRIPTOR_SLOTS {
			binding.writes[frame] = vulkan.WriteDescriptorSet{
				sType           = .WRITE_DESCRIPTOR_SET,
				dstBinding      = spec.binding,
				dstArrayElement = 0,
				descriptorType  = spec.descriptor,
				descriptorCount = 1,
			}
			if spec.external {continue}
			binding.buffers[frame] = buffer_init(gpu, spec.size, {.UNIFORM_BUFFER}, .HostVisible) or_return
			binding.buffer_infos[frame] = vulkan.DescriptorBufferInfo{
				buffer = binding.buffers[frame].buffer,
				offset = 0,
				range  = spec.size,
			}
			binding.writes[frame].pBufferInfo = &binding.buffer_infos[frame]
		}
	}

	log.debugf("[VULKAN]   Push descriptors ready (%d bindings)", len(tmp.bindings))
	committed = true
	return tmp, true
}

@(private)
push_descriptors_destroy :: proc(self: ^Push_Descriptors) {
	if self.gpu == nil {return}
	log.debugf("[VULKAN] Destroying Push descriptors...")
	for &binding in self.bindings {
		for &buffer in binding.buffers {buffer_destroy(&buffer)}
	}
	delete(self.bindings)
	self.bindings = nil
}

@(private)
push_descriptors_find :: proc(self: ^Push_Descriptors, set, binding: u32) -> ^Push_Binding {
	for &entry in self.bindings {
		if entry.set == set && entry.binding == binding {return &entry}
	}
	return nil
}

@(private)
push_descriptors_buffer :: proc(self: ^Push_Descriptors, set, binding, frame: u32) -> vulkan.Buffer {
	entry := push_descriptors_find(self, set, binding)
	if entry == nil {return 0}
	return entry.buffers[frame].buffer
}

// push_descriptors_validate checks the configured bindings against the merged
// shader interface, copies each binding's stage flags and warns about shader
// resources that no buffer feeds.
@(private)
push_descriptors_validate :: proc(self: ^Push_Descriptors, pipeline: ^Pipeline) -> bool {
	for &entry in self.bindings {
		merged, found := pipeline_descriptor(pipeline, entry.set, entry.binding)
		if !found {
			log.errorf(
				"[VULKAN] Push descriptor set %d binding %d is not declared by the shaders",
				entry.set,
				entry.binding,
			)
			return false
		}
		if merged.descriptor != entry.descriptor {
			log.errorf(
				"[VULKAN] Push descriptor set %d binding %d is %v in the shader but %v in the config",
				entry.set,
				entry.binding,
				merged.descriptor,
				entry.descriptor,
			)
			return false
		}
		entry.stage = merged.stage
	}

	for descriptor in pipeline.descriptors {
		if push_descriptors_find(self, descriptor.set, descriptor.binding) == nil {
			log.warnf(
				"[VULKAN] Shader descriptor set %d binding %d has no configured buffer",
				descriptor.set,
				descriptor.binding,
			)
		}
	}
	return true
}

@(private)
push_descriptors_write :: proc(
	self: ^Push_Descriptors,
	set, binding: u32,
	frame: u32,
	data: rawptr,
	size: vulkan.DeviceSize,
) {
	entry := push_descriptors_find(self, set, binding)
	assert(entry != nil, "push descriptor binding is not configured")
	assert(frame < MAX_FRAMES_IN_FLIGHT, "push descriptor frame out of range")
	assert(size <= entry.size, "push descriptor write exceeds the binding size")
	buffer_write(&entry.buffers[frame], data, size, 0)
}

// push_descriptors_bind_buffer points an external binding at a caller-owned
// buffer for this frame. The binding is pushed on the next flush (once).
@(private)
push_descriptors_bind_buffer :: proc(
	self: ^Push_Descriptors,
	set, binding, frame: u32,
	buffer: vulkan.Buffer,
	offset: vulkan.DeviceSize,
	size: vulkan.DeviceSize,
) {
	entry := push_descriptors_find(self, set, binding)
	assert(entry != nil, "push descriptor binding is not configured")
	assert(entry.external, "push_descriptors_bind_buffer on a binding that owns its buffer")
	assert(frame < PUSH_DESCRIPTOR_SLOTS, "push descriptor frame out of range")
	assert(buffer != 0, "push_descriptors_bind_buffer with a null buffer")
	entry.buffer_infos[frame] = vulkan.DescriptorBufferInfo{
		buffer = buffer,
		offset = offset,
		range  = size,
	}
	entry.bound[frame] = true
}

@(private)
push_descriptors_flush :: proc(
	self: ^Push_Descriptors,
	cmd: vulkan.CommandBuffer,
	layout: vulkan.PipelineLayout,
	frame: u32,
) {
	assert(frame < PUSH_DESCRIPTOR_SLOTS, "push descriptor frame out of range")
	for &entry in self.bindings {
		// An external binding that was not supplied this frame is skipped: the
		// recording path is responsible for binding everything its dispatch reads.
		if entry.external && !entry.bound[frame] {continue}
		// Recomputed every frame so the write never points at a stale address.
		entry.writes[frame].pBufferInfo = &entry.buffer_infos[frame]
		info := vulkan.PushDescriptorSetInfo{
			sType                = .PUSH_DESCRIPTOR_SET_INFO,
			stageFlags           = entry.stage,
			layout               = layout,
			set                  = entry.set,
			descriptorWriteCount = 1,
			pDescriptorWrites    = &entry.writes[frame],
		}
		vulkan.CmdPushDescriptorSet2(cmd, &info)
		if entry.external {entry.bound[frame] = false}
	}
}
