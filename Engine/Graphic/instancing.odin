package graphic

import phys "../physic"
import "base:intrinsics"
import "vendor:vulkan"

InstanceBuffer :: struct {
	gpu:      ^GPU,
	buffers:  [MAX_FRAMES_IN_FLIGHT]Buffer,
	capacity: int,
	has_data: [MAX_FRAMES_IN_FLIGHT]bool,
}

INSTANCE_SCALE :: 0.00001

instance_buffer_create :: proc(gpu: ^GPU) -> (self: InstanceBuffer, ok: bool) {
	self.gpu = gpu
	return self, true
}

instance_buffer_destroy :: proc(self: ^InstanceBuffer) {
	for &buffer in self.buffers {
		if buffer.buffer != 0 {
			buffer_destroy(&buffer)
		}
	}
	self.capacity = 0
	self.has_data = {}
}

instance_buffer_ensure :: proc(self: ^InstanceBuffer, count: int) {
	if count <= self.capacity && self.buffers[0].buffer != 0 {return}
	for &buffer in self.buffers {
		if buffer.buffer != 0 {buffer_destroy(&buffer)}
	}
	size := vulkan.DeviceSize(size_of(InstanceData) * vulkan.DeviceSize(max(count, 1)))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer, _ := buffer_create(self.gpu, size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		self.buffers[i] = buffer
		buffer_map(&self.buffers[i])
	}
	self.capacity = count
	self.has_data = {}
}

instance_buffer_write_static :: proc(self: ^InstanceBuffer, objects: []phys.PhysicObject) {
	if len(objects) == 0 {return}
	instance_buffer_ensure(self, len(objects))
	for &buffer in self.buffers {
		if buffer.mapped == nil {continue}
		for obj, i in objects {
			data := InstanceData{
				radius   = obj.radius * INSTANCE_SCALE,
				selected = i32(obj.selected),
			}
			intrinsics.mem_copy(rawptr(uintptr(buffer.mapped) + uintptr(i * size_of(InstanceData))), &data, size_of(InstanceData))
		}
	}
	self.has_data = {}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {self.has_data[i] = true}
}

instance_buffer_update_positions :: proc(self: ^InstanceBuffer, frame: u32, positions: []Vec3) {
	if len(positions) == 0 || frame >= MAX_FRAMES_IN_FLIGHT {return}
	buffer := &self.buffers[frame]
	if buffer.mapped == nil || !self.has_data[frame] {return}
	for pos, i in positions {
		if i >= self.capacity {break}
		scaled := pos * INSTANCE_SCALE
		intrinsics.mem_copy(rawptr(uintptr(buffer.mapped) + uintptr(i * size_of(InstanceData))), &scaled, size_of(Vec3))
	}
}

instance_buffer_bind :: proc(self: ^InstanceBuffer, cmd: vulkan.CommandBuffer, frame: u32) {
	if frame >= MAX_FRAMES_IN_FLIGHT || !self.has_data[frame] || self.buffers[frame].buffer == 0 {return}
	offset: vulkan.DeviceSize = 0
	vulkan.CmdBindVertexBuffers(cmd, 1, 1, &self.buffers[frame].buffer, &offset)
}
