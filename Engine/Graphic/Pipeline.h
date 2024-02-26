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
			VkDescriptorSetLayout getDescriptorSetLayout() { return descriptorSetLayout; }
			VkPipelineLayout getPipelineLayout() { return pipelineLayout; }
		private:
			GPU& gpu;
			VkPipelineLayout pipelineLayout;
			VkPipeline graphicsPipeline;
			VkDescriptorSetLayout descriptorSetLayout;
			std::vector<VkDynamicState> dynamicStates = {
				VK_DYNAMIC_STATE_VIEWPORT,
				VK_DYNAMIC_STATE_SCISSOR
			};

			VkShaderModule createShaderModule(const std::vector<char>& code);
			void createDescriptorSetLayout(VkDevice device);
		};

	}
	
}

