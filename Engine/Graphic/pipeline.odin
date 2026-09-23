package graphic

import "core:log"
import "core:os"
import "core:strings"
import "vendor:vulkan"
import spirv "./spirv"

// A descriptor binding merged across every shader stage of the pipeline. The
// name is borrowed from the reflection that declared it.
@(private)
Merged_Descriptor :: struct {
	set:         u32,
	binding:     u32,
	descriptor:  vulkan.DescriptorType,
	stage:       vulkan.ShaderStageFlags,
	array_count: u32,
	name:        string,
}

@(private)
Pipeline :: struct {
	gpu:          ^GPU,
	layout:       vulkan.PipelineLayout,
	handle:       vulkan.Pipeline,
	set_layouts:  [dynamic]vulkan.DescriptorSetLayout,
	color_format: vulkan.Format,
	depth_format: vulkan.Format,
	reflections:  [dynamic]spirv.Reflection,
	descriptors:  [dynamic]Merged_Descriptor,
}

// Pipeline handles are indices into the registry, so a Frame_Pass can name its
// pipeline without owning it. The registry replaces the single Renderer.pipeline
// and is what makes a second pass mechanical to add.
@(private)
Pipeline_ID :: distinct u32

@(private)
Pipeline_Entry :: struct {
	name:     string,
	pipeline: Pipeline,
}

@(private)
Pipeline_Registry :: struct {
	gpu:     ^GPU,
	entries: [dynamic]Pipeline_Entry,
}

@(private)
pipeline_registry_init :: proc(gpu: ^GPU) -> Pipeline_Registry {
	return Pipeline_Registry{gpu = gpu, entries = make([dynamic]Pipeline_Entry, 0, 4)}
}

@(private)
pipeline_registry_add :: proc(
	self: ^Pipeline_Registry,
	name: string,
	cfg: Pipeline_Config,
	color_format, depth_format: vulkan.Format,
) -> (
	id: Pipeline_ID,
	ok: bool,
) {
	pipeline := pipeline_init(self.gpu, cfg, color_format, depth_format) or_return
	append(&self.entries, Pipeline_Entry{name = name, pipeline = pipeline})
	return Pipeline_ID(len(self.entries) - 1), true
}

@(private)
pipeline_registry_get :: proc(self: ^Pipeline_Registry, id: Pipeline_ID) -> ^Pipeline {
	assert(u32(id) < u32(len(self.entries)), "pipeline id is not registered")
	return &self.entries[u32(id)].pipeline
}

@(private)
pipeline_registry_destroy :: proc(self: ^Pipeline_Registry) {
	for &entry in self.entries {pipeline_destroy(&entry.pipeline)}
	delete(self.entries)
	self.entries = nil
}

// pipeline_init builds the whole pipeline from a declarative config: shader
// modules, vertex input and descriptor set layouts all come from SPIR-V
// reflection, while the CPU-side buffer structs provide offsets and strides.
@(private)
pipeline_init :: proc(
	gpu: ^GPU,
	cfg: Pipeline_Config,
	color_format, depth_format: vulkan.Format,
) -> (
	result: Pipeline,
	ok: bool,
) {
	log.debugf("[VULKAN] Pipeline initialization...")
	tmp := Pipeline{
		gpu          = gpu,
		color_format = color_format,
		depth_format = depth_format,
	}
	tmp.reflections = make([dynamic]spirv.Reflection, 0, len(cfg.shaders))
	tmp.descriptors = make([dynamic]Merged_Descriptor, 0, 8)
	tmp.set_layouts = make([dynamic]vulkan.DescriptorSetLayout, 0, 1)
	committed := false
	defer if !committed {pipeline_destroy(&tmp)}

	log.debugf("[VULKAN]   Loading and reflecting shaders...")
	modules := make([dynamic]vulkan.ShaderModule, 0, len(cfg.shaders))
	defer {
		for module in modules {vulkan.DestroyShaderModule(gpu.device, module, nil)}
		delete(modules)
	}
	stages := make([dynamic]vulkan.PipelineShaderStageCreateInfo, 0, len(cfg.shaders))

	vertex_inputs: []spirv.Input
	for spec in cfg.shaders {
		code, read_err := os.read_entire_file(spec.path, context.temp_allocator)
		if read_err != nil {
			log.errorf("[VULKAN] Failed to load shader %s", spec.path)
			return {}, false
		}

		reflection, reflected := spirv.reflect_with_allocator(code, context.allocator)
		if !reflected {
			log.errorf("[VULKAN] Failed to reflect shader %s", spec.path)
			return {}, false
		}
		append(&tmp.reflections, reflection)

		entry, _ := strings.clone_to_cstring(reflection.entry_point, context.temp_allocator)
		module := _create_shader_module(gpu, code)
		append(&modules, module)
		append(&stages, vulkan.PipelineShaderStageCreateInfo{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {spirv.stage_flag(reflection.stage)},
			module = module,
			pName  = entry,
		})
		log.debugf(
			"[VULKAN]     %s: %s (%d bytes)",
			spec.path,
			reflection.entry_point,
			len(code),
		)

		if reflection.stage == .Vertex {vertex_inputs = reflection.inputs}
	}
	if len(stages) == 0 {
		log.errorf("[VULKAN] Pipeline config declares no shaders")
		return {}, false
	}

	log.debugf("[VULKAN]   Building vertex input...")
	vertex_input, vertex_ok := _build_vertex_input(cfg, vertex_inputs)
	if !vertex_ok {return {}, false}
	defer {
		delete(vertex_input.bindings)
		delete(vertex_input.attributes)
	}

	log.debugf("[VULKAN]   Creating descriptor set layouts...")
	if !_merge_descriptors(tmp.reflections[:], &tmp.descriptors) {return {}, false}
	if !_create_set_layouts(gpu, tmp.descriptors[:], &tmp.set_layouts) {return {}, false}

	pipeline_layout_info := vulkan.PipelineLayoutCreateInfo{
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = u32(len(tmp.set_layouts)),
		pSetLayouts    = raw_data(tmp.set_layouts),
	}
	vk_check(
		vulkan.CreatePipelineLayout(gpu.device, &pipeline_layout_info, nil, &tmp.layout),
		"vkCreatePipelineLayout",
	) or_return

	log.debugf("[VULKAN]   Creating graphics pipeline...")
	fixed := cfg.fixed
	vertex_info := vulkan.PipelineVertexInputStateCreateInfo{
		sType                         = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = u32(len(vertex_input.bindings)),
		pVertexBindingDescriptions    = raw_data(vertex_input.bindings),
		vertexAttributeDescriptionCount = u32(len(vertex_input.attributes)),
		pVertexAttributeDescriptions  = raw_data(vertex_input.attributes),
	}
	input_assembly := vulkan.PipelineInputAssemblyStateCreateInfo{
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = fixed.topology,
		primitiveRestartEnable = false,
	}
	viewport_state := vulkan.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterizer := vulkan.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = fixed.polygon_mode,
		cullMode    = fixed.cull_mode,
		frontFace   = fixed.front_face,
		lineWidth   = fixed.line_width,
	}
	multisampling := vulkan.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = fixed.samples,
		minSampleShading     = 1,
	}
	depth_stencil := vulkan.PipelineDepthStencilStateCreateInfo{
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = b32(fixed.depth_test),
		depthWriteEnable = b32(fixed.depth_write),
		depthCompareOp   = fixed.depth_compare,
	}
	color_blend_attach := vulkan.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable    = b32(fixed.blend_enable),
	}
	if fixed.blend_enable {
		color_blend_attach.srcColorBlendFactor = .SRC_ALPHA
		color_blend_attach.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attach.colorBlendOp        = .ADD
		color_blend_attach.srcAlphaBlendFactor = .ONE
		color_blend_attach.dstAlphaBlendFactor = .ZERO
		color_blend_attach.alphaBlendOp        = .ADD
	}
	color_blending := vulkan.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		attachmentCount = 1,
		pAttachments    = &color_blend_attach,
	}
	dynamic_state := vulkan.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(fixed.dynamic_states)),
		pDynamicStates    = raw_data(fixed.dynamic_states),
	}

	// Dynamic rendering: the pipeline declares its attachment formats instead of
	// referencing a VkRenderPass, so it no longer depends on the swapchain.
	color_format_local := color_format
	rendering_info := vulkan.PipelineRenderingCreateInfo{
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format_local,
		depthAttachmentFormat   = depth_format,
	}
	pipeline_info := vulkan.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = u32(len(stages)),
		pStages             = raw_data(stages),
		pVertexInputState   = &vertex_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pDepthStencilState  = &depth_stencil,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = tmp.layout,
	}
	vk_check(
		vulkan.CreateGraphicsPipelines(gpu.device, 0, 1, &pipeline_info, nil, &tmp.handle),
		"vkCreateGraphicsPipelines",
	) or_return

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
	for layout in self.set_layouts {
		if layout != 0 {vulkan.DestroyDescriptorSetLayout(self.gpu.device, layout, nil)}
	}
	delete(self.set_layouts)
	for &reflection in self.reflections {spirv.reflection_destroy(&reflection)}
	delete(self.reflections)
	delete(self.descriptors)
	log.debugf("[VULKAN]   Pipeline destroyed")
}

@(private)
pipeline_bind :: proc(self: ^Pipeline, cmd: vulkan.CommandBuffer) {
	vulkan.CmdBindPipeline(cmd, .GRAPHICS, self.handle)
}

// pipeline_descriptor looks up a merged descriptor by its Vulkan location.
@(private)
pipeline_descriptor :: proc(self: ^Pipeline, set, binding: u32) -> (Merged_Descriptor, bool) {
	for descriptor in self.descriptors {
		if descriptor.set == set && descriptor.binding == binding {return descriptor, true}
	}
	return {}, false
}

// _merge_descriptors collapses the per-stage descriptor lists into one list per
// (set, binding), unioning the stages that consume each binding.
@(private)
_merge_descriptors :: proc(reflections: []spirv.Reflection, out: ^[dynamic]Merged_Descriptor) -> bool {
	for reflection in reflections {
		stage := vulkan.ShaderStageFlags{spirv.stage_flag(reflection.stage)}
		for descriptor in reflection.descriptors {
			found := false
			for &merged in out {
				if merged.set != descriptor.set || merged.binding != descriptor.binding {continue}
				if merged.descriptor != descriptor.descriptor {
					log.errorf(
						"[VULKAN] Descriptor set %d binding %d has conflicting types across stages",
						descriptor.set,
						descriptor.binding,
					)
					return false
				}
				merged.stage |= stage
				found = true
				break
			}
			if !found {
				append(out, Merged_Descriptor{
					set         = descriptor.set,
					binding     = descriptor.binding,
					descriptor  = descriptor.descriptor,
					stage       = stage,
					array_count = descriptor.array_count,
					name        = descriptor.name,
				})
			}
		}
	}
	return true
}

// _create_set_layouts builds one push-descriptor set layout per set index found
// in the shader interface. Unused indices in between become empty layouts so
// set indices stay stable.
@(private)
_create_set_layouts :: proc(
	gpu: ^GPU,
	descriptors: []Merged_Descriptor,
	out: ^[dynamic]vulkan.DescriptorSetLayout,
) -> bool {
	if len(descriptors) == 0 {return true}

	max_set := u32(0)
	for descriptor in descriptors {
		if descriptor.set > max_set {max_set = descriptor.set}
	}

	for set in 0 ..= max_set {
		bindings := make([dynamic]vulkan.DescriptorSetLayoutBinding, 0, 4, context.temp_allocator)
		for descriptor in descriptors {
			if descriptor.set != set {continue}
			count := descriptor.array_count
			if count == 0 {count = 1}
			append(&bindings, vulkan.DescriptorSetLayoutBinding{
				binding         = descriptor.binding,
				descriptorType  = descriptor.descriptor,
				descriptorCount = count,
				stageFlags      = descriptor.stage,
			})
		}
		layout_info := vulkan.DescriptorSetLayoutCreateInfo{
			sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			flags        = {.PUSH_DESCRIPTOR},
			bindingCount = u32(len(bindings)),
			pBindings    = raw_data(bindings),
		}
		layout: vulkan.DescriptorSetLayout
		if !vk_check(
			vulkan.CreateDescriptorSetLayout(gpu.device, &layout_info, nil, &layout),
			"vkCreateDescriptorSetLayout",
		) {
			return false
		}
		append(out, layout)
	}
	return true
}

@(private)
_create_shader_module :: proc(gpu: ^GPU, code: []byte) -> vulkan.ShaderModule {
	create_info := vulkan.ShaderModuleCreateInfo{
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)(raw_data(code)),
	}
	module: vulkan.ShaderModule
	// Invalid SPIR-V is a programming error, not a runtime condition.
	vk_assert(vulkan.CreateShaderModule(gpu.device, &create_info, nil, &module), "vkCreateShaderModule")
	return module
}
