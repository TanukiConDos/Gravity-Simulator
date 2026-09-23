package graphic

import "vendor:vulkan"

@(private)
MAX_FRAMES_IN_FLIGHT :: 2

// Upper bound for a frame pass's color attachments (and a pipeline's color
// output formats). The renderer currently uses two: swapchain color + pick ID.
@(private)
MAX_COLOR_ATTACHMENTS :: 4

@(private)
Vec3 :: [3]f32

@(private)
Vertex :: struct #packed {
	pos:   [3]f32,
	color: [3]f32,
}

@(private)
UniformBufferObject :: struct #align(16) {
	view: matrix[4, 4]f32,
	proj: matrix[4, 4]f32,
}

#assert(size_of(UniformBufferObject) == 128)

@(private)
InstanceData :: struct #packed {
	position: Vec3,
	radius:   f32,
	selected: i32,
	_pad:     [12]u8,
}

#assert(size_of(InstanceData) == 32)

// Stored as a world resource so the input system can reach the window without
// the scheduler having to carry a context pointer.
@(private)
Window_Ref :: struct {
	window: ^Window,
}
