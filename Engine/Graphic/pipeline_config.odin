package graphic

import "vendor:vulkan"

// Declarative description of a graphics pipeline. Vertex attributes are not
// listed here: their locations and formats come from SPIR-V reflection and the
// CPU struct layout (see vertex_input.odin), and descriptor set layouts come
// from the shader interface (see pipeline.odin).
@(private)
Shader_Spec :: struct {
	path: string,
}

// A CPU-side vertex stream. `type` is the packed struct written to the buffer;
// its non-underscore fields are paired, in declaration order, with the shader's
// input locations (also in ascending order). `_`-prefixed fields are skipped as
// padding.
@(private)
Vertex_Buffer_Spec :: struct {
	binding:    u32,
	input_rate: vulkan.VertexInputRate,
	type:       typeid,
}

@(private)
Fixed_State :: struct {
	topology:       vulkan.PrimitiveTopology,
	polygon_mode:   vulkan.PolygonMode,
	cull_mode:      vulkan.CullModeFlags,
	front_face:     vulkan.FrontFace,
	line_width:     f32,
	samples:        vulkan.SampleCountFlags,
	depth_test:     bool,
	depth_write:    bool,
	depth_compare:  vulkan.CompareOp,
	blend_enable:   bool,
	dynamic_states: []vulkan.DynamicState,
}

@(private)
Pipeline_Config :: struct {
	shaders:        []Shader_Spec,
	vertex_buffers: []Vertex_Buffer_Spec,
	fixed:          Fixed_State,
}
