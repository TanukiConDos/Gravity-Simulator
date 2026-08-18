package graphic

import phys "../physic"
import "base:intrinsics"
import "vendor:vulkan"

InstanceBuffer :: struct {
	gpu:       ^GPU,
	buffer:    Buffer,
	capacity:  int,
	has_data:  bool,
}

INSTANCE_SCALE :: 0.00001

instance_buffer_create :: proc(gpu: ^GPU) -> (self: InstanceBuffer, ok: bool) {
	self.gpu = gpu
	return self, true
}

instance_buffer_destroy :: proc(self: ^InstanceBuffer) {
	if self.buffer.buffer != 0 {
		buffer_destroy(&self.buffer)
	}
	self.capacity = 0
	self.has_data = false
}

instance_buffer_ensure :: proc(self: ^InstanceBuffer, count: int) {
	if count <= self.capacity && self.buffer.buffer != 0 {return}
	if self.buffer.buffer != 0 {buffer_destroy(&self.buffer)}
	size := vulkan.DeviceSize(size_of(InstanceData) * vulkan.DeviceSize(max(count, 1)))
	buffer, _ := buffer_create(self.gpu, size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	self.buffer = buffer
	buffer_map(&self.buffer)
	self.capacity = count
	self.has_data = false
}

instance_buffer_update :: proc(self: ^InstanceBuffer, objects: []phys.PhysicObject) {
	if len(objects) == 0 {return}
	instance_buffer_ensure(self, len(objects))
	mapped := self.buffer.mapped
	if mapped == nil {return}
	for obj, i in objects {
		data := InstanceData{
			position = obj.position * INSTANCE_SCALE,
			radius   = obj.radius * INSTANCE_SCALE,
			selected = i32(obj.selected),
		}
		intrinsics.mem_copy(rawptr(uintptr(mapped) + uintptr(i * size_of(InstanceData))), &data, size_of(InstanceData))
	}
	self.has_data = true
}

instance_buffer_bind :: proc(self: ^InstanceBuffer, cmd: vulkan.CommandBuffer) {
	if !self.has_data || self.buffer.buffer == 0 {return}
	offset: vulkan.DeviceSize = 0
	vulkan.CmdBindVertexBuffers(cmd, 1, 1, &self.buffer.buffer, &offset)
}
