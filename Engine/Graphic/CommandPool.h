#pragma once
#include <vulkan/vulkan.hpp>
#include "Graphic.h"
#include "GPU.h"
#include "Pipeline.h"

namespace Engine
{
	namespace Graphic
	{

		class CommandPool
		{
		public:

			CommandPool(const CommandPool&) = delete;
			CommandPool& operator=(const CommandPool&) = delete;

			CommandPool(GPU& gpu);
			~CommandPool();

			VkCommandBuffer beginCommandBuffer(uint32_t imageIndex);
			void endCommandBuffer(VkCommandBuffer commandBuffer);
			void resetCommandBuffer(uint32_t currentFrame);
			VkCommandBuffer createTemporalCommandBuffer();
			void endTemporalCommandBuffer(VkCommandBuffer commandBuffer);
			
		private:
			GPU& _gpu;
			VkCommandPool _commandPool;
			std::vector<VkCommandBuffer> _commandBuffers;

			void createCommandBuffer();
			void createCommandPool();
			
		};
	}
	
}
