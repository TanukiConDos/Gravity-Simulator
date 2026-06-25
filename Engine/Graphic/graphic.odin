package graphic

import "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 1

Vec3 :: [3]f32

Vertex :: struct #packed {
	pos:   [3]f32,
	color: [3]f32,
}

UniformBufferObject :: struct #align(16) {
	model:    matrix[4, 4]f32,
	view:     matrix[4, 4]f32,
	proj:     matrix[4, 4]f32,
	selected: i32,
	_pad:     [12]u8,
}

#assert(size_of(UniformBufferObject) == 208)
