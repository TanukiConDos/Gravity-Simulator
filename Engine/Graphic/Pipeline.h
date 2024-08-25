#pragma once
#include<vulkan/vulkan.hpp>

#include "../../Foundation/File.h"
#include "GPU.h"
namespace Engine
{
	namespace Graphic
	{

		class Pipeline
		{
		public:

			Pipeline(const Pipeline&) = delete;
			Pipeline& operator=(const Pipeline&) = delete;

			Pipeline(GPU& gpu, VkRenderPass renderPass);
			~Pipeline();
			void bind(VkCommandBuffer commandBuffer);
			VkDescriptorSetLayout getDescriptorSetLayout() { return _descriptorSetLayout; }
			VkPipelineLayout getPipelineLayout() { return _pipelineLayout; }
		private:
			GPU& _gpu;
			VkPipelineLayout _pipelineLayout;
			VkPipeline _graphicsPipeline;
			VkDescriptorSetLayout _descriptorSetLayout;
			const std::vector<VkDynamicState> _dynamicStates = {
				VK_DYNAMIC_STATE_VIEWPORT,
				VK_DYNAMIC_STATE_SCISSOR
			};

			VkShaderModule createShaderModule(const std::vector<char>& code);
			void createDescriptorSetLayout(VkDevice device);
		};

	}
	
}

