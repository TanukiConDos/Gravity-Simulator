package graphic

import ecs "../ecs"
import phys "../physic"
import "base:intrinsics"
import "vendor:vulkan"

@(private)
InstanceBuffer :: struct {
	gpu:      ^GPU,
	buffers:  [MAX_FRAMES_IN_FLIGHT]Buffer,
	capacity: int,
	has_data: [MAX_FRAMES_IN_FLIGHT]bool,
}

@(private)
INSTANCE_SCALE :: 0.00001

@(private)
instance_buffer_init :: proc(gpu: ^GPU) -> InstanceBuffer {return InstanceBuffer{gpu = gpu}}

@(private)
instance_buffer_destroy :: proc(self: ^InstanceBuffer) {
	for &buffer in self.buffers {buffer_destroy(&buffer)}
	self.capacity = 0
	self.has_data = {}
}

@(private)
instance_buffer_ensure :: proc(self: ^InstanceBuffer, count: int) {
	if count <= self.capacity && self.buffers[0].buffer != 0 {return}
	for &buffer in self.buffers {buffer_destroy(&buffer)}
	size := vulkan.DeviceSize(size_of(InstanceData) * vulkan.DeviceSize(max(count, 1)))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		// Runtime reallocation has no recovery path.
		buffer, created := buffer_init(self.gpu, size, {.VERTEX_BUFFER}, .HostVisible)
		assert(created, "failed to create instance buffer")
		self.buffers[i] = buffer
	}
	self.capacity = count
	self.has_data = {}
}

@(private)
instance_buffer_write_static :: proc(self: ^InstanceBuffer, world: ^ecs.World) {
	view := phys.body_view(world)
	count := len(view.bodies)
	if count == 0 {return}
	instance_buffer_ensure(self, count)
	for &buffer in self.buffers {
		if buffer.mapped == nil {continue}
		for idx, i in view.bodies {
			selected := i32(0)
			if bool(view.selected[idx]) {selected = 1}
			data := InstanceData {
				radius   = f32(view.radius[idx]) * INSTANCE_SCALE,
				selected = selected,
			}
			intrinsics.mem_copy(
				rawptr(uintptr(buffer.mapped) + uintptr(i * size_of(InstanceData))),
				&data,
				size_of(InstanceData),
			)
		}
	}
	self.has_data = {}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {self.has_data[i] = true}
}

@(private)
instance_buffer_update_positions :: proc(self: ^InstanceBuffer, frame: u32, positions: []Vec3, selected: []u8) {
	if len(positions) == 0 {return}
	assert(frame < MAX_FRAMES_IN_FLIGHT, "instance frame index out of range")
	assert(self.has_data[frame], "instance buffer for this frame has no static data")
	assert(len(positions) <= self.capacity, "more positions than the instance buffer capacity")
	assert(len(selected) >= len(positions), "fewer selection flags than positions")
	buffer := &self.buffers[frame]
	assert(buffer.mapped != nil, "instance buffer is not mapped")
	base := uintptr(buffer.mapped)
	for pos, i in positions {
		scaled := pos * INSTANCE_SCALE
		entry := base + uintptr(i * size_of(InstanceData))
		intrinsics.mem_copy(rawptr(entry), &scaled, size_of(Vec3))
		flag := selected[i] > 0 ? i32(1) : i32(0)
		intrinsics.mem_copy(rawptr(entry + offset_of(InstanceData, selected)), &flag, size_of(i32))
	}
}

@(private)
instance_buffer_bind :: proc(
	self: ^InstanceBuffer,
	cmd: vulkan.CommandBuffer,
	frame: u32,
	binding: u32,
) {
	assert(frame < MAX_FRAMES_IN_FLIGHT, "instance frame index out of range")
	// No static data (empty scene) is a legitimate state, not an error.
	if !self.has_data[frame] || self.buffers[frame].buffer == 0 {return}
	offset: vulkan.DeviceSize = 0
	vulkan.CmdBindVertexBuffers(cmd, binding, 1, &self.buffers[frame].buffer, &offset)
}
