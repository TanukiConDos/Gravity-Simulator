package graphic

import "core:log"
import "core:os"
import "vendor:vulkan"

@(private)
Pipeline :: struct {
	gpu:                    ^GPU,
	layout:                 vulkan.PipelineLayout,
	handle:                 vulkan.Pipeline,
	descriptor_set_layout:  vulkan.DescriptorSetLayout,
	color_format:           vulkan.Format,
	depth_format:           vulkan.Format,
}

@(private)
pipeline_init :: proc(gpu: ^GPU, color_format, depth_format: vulkan.Format) -> (result: Pipeline, ok: bool) {
	log.debugf("[VULKAN] Pipeline initialization...")
	tmp := Pipeline{gpu = gpu, color_format = color_format, depth_format = depth_format}
	committed := false
	defer if !committed {pipeline_destroy(&tmp)}

	log.debugf("[VULKAN]   Loading shaders...")
	vertex_code, vertex_err := os.read_entire_file("Engine/Graphic/shader/vert.spv", context.temp_allocator)
	fragment_code, fragment_err := os.read_entire_file("Engine/Graphic/shader/frag.spv", context.temp_allocator)
	if vertex_err != nil || fragment_err != nil {log.errorf("[VULKAN] Failed to load shaders!"); return {}, false}
	log.debugf("[VULKAN]     Vert: %d bytes  Frag: %d bytes", len(vertex_code), len(fragment_code))

	log.debugf("[VULKAN]   Creating shader modules...")
	vertex_module := _create_shader_module(gpu, vertex_code)
	fragment_module := _create_shader_module(gpu, fragment_code)
	defer {
		vulkan.DestroyShaderModule(gpu.device, vertex_module, nil)
		vulkan.DestroyShaderModule(gpu.device, fragment_module, nil)
	}
	log.debugf("[VULKAN]     Shader modules created")

	binding_descriptions := [?]vulkan.VertexInputBindingDescription{
		{binding = 0, stride = u32(size_of(Vertex)), inputRate = .VERTEX},
		{binding = 1, stride = u32(size_of(InstanceData)), inputRate = .INSTANCE},
	}
	attribute_descriptions := [?]vulkan.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		{location = 2, binding = 1, format = .R32G32B32_SFLOAT, offset = u32(offset_of(InstanceData, position))},
		{location = 3, binding = 1, format = .R32_SFLOAT, offset = u32(offset_of(InstanceData, radius))},
		{location = 4, binding = 1, format = .R32_SINT, offset = u32(offset_of(InstanceData, selected))},
	}

	log.debugf("[VULKAN]   Creating descriptor set layout...")
	// PUSH_DESCRIPTOR: the camera uniform is uploaded per draw through
	// vkCmdPushDescriptorSet2, so no descriptor pool/sets are needed.
	ubo_layout_binding := vulkan.DescriptorSetLayoutBinding{binding = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX}}
	layout_info := vulkan.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, flags = {.PUSH_DESCRIPTOR}, bindingCount = 1, pBindings = &ubo_layout_binding}
	vk_check(vulkan.CreateDescriptorSetLayout(gpu.device, &layout_info, nil, &tmp.descriptor_set_layout), "vkCreateDescriptorSetLayout") or_return
	log.debugf("[VULKAN]     Descriptor set layout created")

	log.debugf("[VULKAN]   Creating pipeline layout...")
	pipeline_layout_info := vulkan.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 1, pSetLayouts = &tmp.descriptor_set_layout}
	vk_check(vulkan.CreatePipelineLayout(gpu.device, &pipeline_layout_info, nil, &tmp.layout), "vkCreatePipelineLayout") or_return
	log.debugf("[VULKAN]     Pipeline layout created")

	log.debugf("[VULKAN]   Creating graphics pipeline...")
	vertex_info := vulkan.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = 2,
		pVertexBindingDescriptions = &binding_descriptions[0],
		vertexAttributeDescriptionCount = 5,
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

	// Dynamic rendering: the pipeline declares its attachment formats instead of
	// referencing a VkRenderPass, so it no longer depends on the swapchain.
	color_format_local := color_format
	rendering_info := vulkan.PipelineRenderingCreateInfo{
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = 1,
		pColorAttachmentFormats = &color_format_local,
		depthAttachmentFormat = depth_format,
	}
	pipeline_info := vulkan.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext = &rendering_info,
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
		layout = tmp.layout,
	}
	vk_check(vulkan.CreateGraphicsPipelines(gpu.device, 0, 1, &pipeline_info, nil, &tmp.handle), "vkCreateGraphicsPipelines") or_return
	log.debugf("[VULKAN]   Pipeline ready")
	committed = true
	return tmp, true
}

@(private)
pipeline_destroy :: proc(self: ^Pipeline) {
	if self.gpu == nil {return}
	log.debugf("[VULKAN] Destroying Pipeline...")
	if self.handle != 0 {vulkan.DestroyPipeline(self.gpu.device, self.handle, nil); self.handle = 0}
	if self.layout != 0 {vulkan.DestroyPipelineLayout(self.gpu.device, self.layout, nil); self.layout = 0}
	if self.descriptor_set_layout != 0 {vulkan.DestroyDescriptorSetLayout(self.gpu.device, self.descriptor_set_layout, nil); self.descriptor_set_layout = 0}
	log.debugf("[VULKAN]   Pipeline destroyed")
}

@(private)
pipeline_bind :: proc(self: ^Pipeline, cmd: vulkan.CommandBuffer) {
	vulkan.CmdBindPipeline(cmd, .GRAPHICS, self.handle)
}

@(private) _create_shader_module :: proc(gpu: ^GPU, code: []byte) -> vulkan.ShaderModule {
	create_info := vulkan.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code), pCode = cast(^u32)(raw_data(code))}
	module: vulkan.ShaderModule
	// Invalid SPIR-V is a programming error, not a runtime condition.
	vk_assert(vulkan.CreateShaderModule(gpu.device, &create_info, nil, &module), "vkCreateShaderModule")
	return module
}
