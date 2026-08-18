package graphic

import "core:log"
import "core:os"
import "vendor:vulkan"

Pipeline :: struct {
	gpu:                    ^GPU,
	layout:                 vulkan.PipelineLayout,
	handle:                 vulkan.Pipeline,
	descriptor_set_layout:  vulkan.DescriptorSetLayout,
}

pipeline_create :: proc(gpu: ^GPU, render_pass: vulkan.RenderPass) -> (pipeline_result: Pipeline, ok: bool) {
	log.debugf("[VULKAN] Pipeline initialization...")
	pipeline_result.gpu = gpu

	log.debugf("[VULKAN]   Loading shaders...")
	vertex_code, vertex_err := os.read_entire_file("Engine/Graphic/shader/vert.spv", context.temp_allocator)
	fragment_code, fragment_err := os.read_entire_file("Engine/Graphic/shader/frag.spv", context.temp_allocator)
	if vertex_err != nil || fragment_err != nil {log.errorf("[VULKAN] Failed to load shaders!"); return {}, false}
	log.debugf("[VULKAN]     Vert: %d bytes  Frag: %d bytes", len(vertex_code), len(fragment_code))

	log.debugf("[VULKAN]   Creating shader modules...")
	vertex_module := _create_shader_module(gpu, vertex_code)
	fragment_module := _create_shader_module(gpu, fragment_code)
	log.debugf("[VULKAN]     Shader modules created")

	binding_desc := vulkan.VertexInputBindingDescription{binding = 0, stride = u32(size_of(Vertex)), inputRate = .VERTEX}
	attribute_descriptions := [?]vulkan.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
	}

	log.debugf("[VULKAN]   Creating descriptor set layout...")
	ubo_layout_binding := vulkan.DescriptorSetLayoutBinding{binding = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX}}
	layout_info := vulkan.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = 1, pBindings = &ubo_layout_binding}
	if vulkan.CreateDescriptorSetLayout(gpu.device, &layout_info, nil, &pipeline_result.descriptor_set_layout) != .SUCCESS {return {}, false}
	log.debugf("[VULKAN]     Descriptor set layout created")

	log.debugf("[VULKAN]   Creating pipeline layout...")
	pipeline_layout_info := vulkan.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 1, pSetLayouts = &pipeline_result.descriptor_set_layout}
	if vulkan.CreatePipelineLayout(gpu.device, &pipeline_layout_info, nil, &pipeline_result.layout) != .SUCCESS {return {}, false}
	log.debugf("[VULKAN]     Pipeline layout created")

	log.debugf("[VULKAN]   Creating graphics pipeline...")
	vertex_info := vulkan.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = 1,
		pVertexBindingDescriptions = &binding_desc,
		vertexAttributeDescriptionCount = 2,
		pVertexAttributeDescriptions = &attribute_descriptions[0],
	}
	input_assembly := vulkan.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}
	vertex_stage := vulkan.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {.VERTEX},
		module = vertex_module,
		pName = "main",
	}
	fragment_stage := vulkan.PipelineShaderStageCreateInfo{
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {.FRAGMENT},
		module = fragment_module,
		pName = "main",
	}
	stages := [?]vulkan.PipelineShaderStageCreateInfo{vertex_stage, fragment_stage}
	viewport_state := vulkan.PipelineViewportStateCreateInfo{
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}
	rasterizer := vulkan.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode = {.BACK},
		frontFace = .CLOCKWISE,
		lineWidth = 1,
	}
	multisampling := vulkan.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading = 1,
	}
	depth_stencil := vulkan.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = true,
		depthWriteEnable = true,
		depthCompareOp = .LESS,
	}
	color_blend_attach := vulkan.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	color_blending := vulkan.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false,
		attachmentCount = 1,
		pAttachments = &color_blend_attach,
	}
	dynamic_states := [?]vulkan.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vulkan.PipelineDynamicStateCreateInfo{
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = &dynamic_states[0],
	}

	pipeline_info := vulkan.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2,
		pStages = &stages[0],
		pVertexInputState = &vertex_info,
		pInputAssemblyState = &input_assembly,
		pViewportState = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState = &multisampling,
		pDepthStencilState = &depth_stencil,
		pColorBlendState = &color_blending,
		pDynamicState = &dynamic_state,
		layout = pipeline_result.layout,
		renderPass = render_pass,
		subpass = 0,
	}
	if vulkan.CreateGraphicsPipelines(gpu.device, 0, 1, &pipeline_info, nil, &pipeline_result.handle) != .SUCCESS {return {}, false}

	vulkan.DestroyShaderModule(gpu.device, vertex_module, nil)
	vulkan.DestroyShaderModule(gpu.device, fragment_module, nil)
	log.debugf("[VULKAN]   Pipeline ready")
	return pipeline_result, true
}

pipeline_destroy :: proc(self: ^Pipeline) {
	log.debugf("[VULKAN] Destroying Pipeline...")
	vulkan.DestroyPipeline(self.gpu.device, self.handle, nil)
	vulkan.DestroyPipelineLayout(self.gpu.device, self.layout, nil)
	vulkan.DestroyDescriptorSetLayout(self.gpu.device, self.descriptor_set_layout, nil)
	log.debugf("[VULKAN]   Pipeline destroyed")
}

pipeline_bind :: proc(self: ^Pipeline, cmd: vulkan.CommandBuffer) {
	vulkan.CmdBindPipeline(cmd, .GRAPHICS, self.handle)
}

@(private) _create_shader_module :: proc(gpu: ^GPU, code: []byte) -> vulkan.ShaderModule {
	create_info := vulkan.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code), pCode = cast(^u32)(raw_data(code))}
	module: vulkan.ShaderModule
	vulkan.CreateShaderModule(gpu.device, &create_info, nil, &module)
	return module
}
