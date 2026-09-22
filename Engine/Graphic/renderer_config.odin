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

@(private)
_RENDERER_DYNAMIC_STATES := [?]vulkan.DynamicState{.VIEWPORT, .SCISSOR}

@(private)
renderer_pipeline_config :: proc() -> Pipeline_Config {
	return Pipeline_Config{
		shaders = RENDERER_SHADERS[:],
		vertex_buffers = RENDERER_VERTEX_BUFFERS[:],
		fixed = Fixed_State{
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
		},
	}
}
