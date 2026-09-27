package graphic

import "vendor:vulkan"

// Single source of truth for the renderer's Vulkan wiring. Adding a vertex
// stream, a shader or a push descriptor means editing this file (and the GLSL
// interface); pipeline.odin derives the rest.

@(private)
MESH_BINDING :: u32(0)
@(private)
INSTANCE_BINDING :: u32(1)

@(private)
CAMERA_SET :: u32(0)
@(private)
CAMERA_BINDING :: u32(0)

@(private)
RENDERER_SHADERS := [?]Shader_Spec{
	{path = "Engine/Graphic/shader/vert.spv"},
	{path = "Engine/Graphic/shader/frag.spv"},
}

// Second color output of the main pass: the instance ID (1-based), so a zero
// pixel means "nothing hit". It is written by the same draw as the swapchain
// color, so no separate pick pass is needed; the format is not the swapchain's.
@(private)
PICK_COLOR_FORMAT :: vulkan.Format.R32_UINT

@(private)
RENDERER_VERTEX_BUFFERS := [?]Vertex_Buffer_Spec{
	{binding = MESH_BINDING, input_rate = .VERTEX, type = Vertex},
	{binding = INSTANCE_BINDING, input_rate = .INSTANCE, type = InstanceData},
}

@(private)
RENDERER_PUSH_BINDINGS := [?]Push_Binding_Spec{
	{
		set = CAMERA_SET,
		binding = CAMERA_BINDING,
		descriptor = .UNIFORM_BUFFER,
		size = size_of(UniformBufferObject),
	},
}

// Direct rendering (M5): when a GPU gravity backend owns the world, a compute
// pass packs the solver's buffers into the instance vertex buffer instead of the
// CPU reading the snapshot. The pass runs on the frame's graphics queue and the
// frame submission waits on the solver's timeline value before it.
@(private)
DIRECT_SHADER :: "Engine/Graphic/shader/instance_pack.spv"

// Must match the shader's local_size_x; used only to size the dispatch.
@(private)
DIRECT_WORKGROUP :: 256

@(private)
DIRECT_SET :: u32(0)
@(private)
DIRECT_BODIES_BINDING :: u32(0)
@(private)
DIRECT_RADII_BINDING :: u32(1)
@(private)
DIRECT_SELECTED_BINDING :: u32(2)
@(private)
DIRECT_LIVE_BINDING :: u32(3)
@(private)
DIRECT_INSTANCES_BINDING :: u32(4)

@(private)
DIRECT_PUSH_BINDINGS := [?]Push_Binding_Spec{
	{set = DIRECT_SET, binding = DIRECT_BODIES_BINDING, descriptor = .STORAGE_BUFFER, external = true},
	{set = DIRECT_SET, binding = DIRECT_RADII_BINDING, descriptor = .STORAGE_BUFFER, external = true},
	{set = DIRECT_SET, binding = DIRECT_SELECTED_BINDING, descriptor = .STORAGE_BUFFER, external = true},
	{set = DIRECT_SET, binding = DIRECT_LIVE_BINDING, descriptor = .STORAGE_BUFFER, external = true},
	{set = DIRECT_SET, binding = DIRECT_INSTANCES_BINDING, descriptor = .STORAGE_BUFFER, external = true},
}

@(private)
Instance_Pack_Push :: struct {
	count: u32,
	mode:  u32,
}

@(private)
_RENDERER_DYNAMIC_STATES := [?]vulkan.DynamicState{.VIEWPORT, .SCISSOR}

@(private)
renderer_pipeline_config :: proc() -> Pipeline_Config {
	return Pipeline_Config {
		shaders = RENDERER_SHADERS[:],
		vertex_buffers = RENDERER_VERTEX_BUFFERS[:],
		fixed = _renderer_fixed_state(),
	}
}

@(private)
_renderer_fixed_state :: proc() -> Fixed_State {
	return Fixed_State {
		topology       = .TRIANGLE_LIST,
		polygon_mode   = .FILL,
		cull_mode      = {.BACK},
		front_face     = .CLOCKWISE,
		line_width     = 1,
		samples        = {._1},
		depth_test     = true,
		depth_write    = true,
		depth_compare  = .LESS,
		blend_enable   = false,
		dynamic_states = _RENDERER_DYNAMIC_STATES[:],
	}
}
