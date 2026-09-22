package graphic

import "vendor:vulkan"

@(private)
MAX_FRAMES_IN_FLIGHT :: 2

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
