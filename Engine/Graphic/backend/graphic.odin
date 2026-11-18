package vk

import gfx "../shared"

// Vulkan-facing constants and vertex formats. The neutral structs that cross
// the seam live in `shared/gfx.odin`; this file keeps the layout the shaders,
// pipelines and GPU buffers agree on.

@(private)
MAX_FRAMES_IN_FLIGHT :: 2

// Command slots in a compute context's submission ring. Independent of the
// renderer's frames in flight; shared state (push descriptor bindings) is sized
// for the larger of the two.
@(private)
COMPUTE_SLOTS :: 3

@(private)
PUSH_DESCRIPTOR_SLOTS :: max(MAX_FRAMES_IN_FLIGHT, COMPUTE_SLOTS)

// Upper bound for a frame pass's color attachments (and a pipeline's color
// output formats). The renderer currently uses two: swapchain color + pick ID.
@(private)
MAX_COLOR_ATTACHMENTS :: 4

@(private)
Vec3 :: gfx.Vec3

@(private)
Vertex :: struct #packed {
	pos:   [3]f32,
	color: [3]f32,
}

@(private)
InstanceData :: struct #packed {
	position: Vec3,
	radius:   f32,
	selected: i32,
	_pad:     [12]u8,
}

#assert(size_of(InstanceData) == 32)
