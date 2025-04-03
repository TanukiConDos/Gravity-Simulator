#include "Pipeline.h"

namespace Engine::Graphic
{
	Pipeline::Pipeline(GPU& gpu, VkRenderPass renderPass): _gpu(gpu)
	{

		Foundation::File vertexShader{ _pipelineConfig.vertexShaderPath };
		Foundation::File fragmentShader{ _pipelineConfig.fragmentShaderPath };

		std::vector<char> vertexShaderCode = vertexShader.read();
		std::vector<char> fragmentShaderCode = fragmentShader.read();

		VkShaderModule vertexShaderModule = createShaderModule(vertexShaderCode);
		VkShaderModule fragmentShaderModule = createShaderModule(fragmentShaderCode);

		_pipelineConfig.vertexShaderStageInfo.module = vertexShaderModule;

		
		_pipelineConfig.fragmentShaderStageInfo.module = fragmentShaderModule;

		std::array<VkPipelineShaderStageCreateInfo, 2> shaderStages = { _pipelineConfig.vertexShaderStageInfo, _pipelineConfig.fragmentShaderStageInfo };

		
		auto bindingDescription = Vertex::getBindingDescription();
		auto attributeDescriptions = Vertex::getAttributeDescriptions();

		_pipelineConfig.vertexInputInfo.vertexAttributeDescriptionCount = static_cast<uint32_t>(attributeDescriptions.size());
		_pipelineConfig.vertexInputInfo.pVertexBindingDescriptions = &bindingDescription;
		_pipelineConfig.vertexInputInfo.pVertexAttributeDescriptions = attributeDescriptions.data();

		_pipelineConfig.dynamicState.dynamicStateCount = static_cast<uint32_t>(_dynamicStates.size());
		_pipelineConfig.dynamicState.pDynamicStates = _dynamicStates.data();

		createDescriptorSetLayout(gpu.getDevice());

		_pipelineConfig.pipelineLayoutInfo.pSetLayouts = &_descriptorSetLayout;

		if (vkCreatePipelineLayout(gpu.getDevice(), &_pipelineConfig.pipelineLayoutInfo, nullptr, &_pipelineLayout) != VK_SUCCESS) {
			throw std::runtime_error("failed to create pipeline layout!");
		}


		_pipelineConfig.pipelineInfo.pStages = shaderStages.data();
		_pipelineConfig.pipelineInfo.layout = _pipelineLayout;
		_pipelineConfig.pipelineInfo.renderPass = renderPass;

		if (vkCreateGraphicsPipelines(gpu.getDevice(), VK_NULL_HANDLE, 1, &_pipelineConfig.pipelineInfo, nullptr, &_graphicsPipeline) != VK_SUCCESS) {
			throw std::runtime_error("failed to create graphics pipeline!");
		}

		vkDestroyShaderModule(gpu.getDevice(), fragmentShaderModule, nullptr);
		vkDestroyShaderModule(gpu.getDevice(), vertexShaderModule, nullptr);
	}

	Pipeline::~Pipeline()
	{
		vkDestroyPipeline(_gpu.getDevice(), _graphicsPipeline, nullptr);
		vkDestroyPipelineLayout(_gpu.getDevice(), _pipelineLayout, nullptr);
	}

	void Pipeline::bind(VkCommandBuffer commandBuffer)
	{
		vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _graphicsPipeline);
	}

	VkShaderModule Pipeline::createShaderModule(const std::vector<char>& code)
	{
		VkShaderModuleCreateInfo createInfo{};
		createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
		createInfo.codeSize = code.size();
		createInfo.pCode = reinterpret_cast<const uint32_t*>(code.data());

		VkShaderModule shaderModule;
		if (vkCreateShaderModule(_gpu.getDevice(), &createInfo, nullptr, &shaderModule) != VK_SUCCESS) {
			throw std::runtime_error("failed to create shader module!");
		}

		return shaderModule;
	}
	void Pipeline::createDescriptorSetLayout(VkDevice device)
	{
		VkDescriptorSetLayoutBinding uboLayoutBinding{};
		uboLayoutBinding.binding = 0;
		uboLayoutBinding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
		uboLayoutBinding.descriptorCount = 1;
		uboLayoutBinding.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
		uboLayoutBinding.pImmutableSamplers = nullptr; // Optional

		VkDescriptorSetLayoutCreateInfo layoutInfo{};
		layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
		layoutInfo.bindingCount = 1;
		layoutInfo.pBindings = &uboLayoutBinding;

		if (vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &_descriptorSetLayout) != VK_SUCCESS) {
			throw std::runtime_error("failed to create descriptor set layout!");
		}
	}
}