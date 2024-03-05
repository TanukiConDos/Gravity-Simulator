#pragma once
#include <vulkan/vulkan.hpp>
#include "GPU.h"
#include "Pipeline.h"
#include "Buffer.h"

namespace Engine
{
	namespace Graphic
	{
		
		class DescriptorPool
		{
		public:

			DescriptorPool(const DescriptorPool&) = delete;
			DescriptorPool& operator=(const DescriptorPool&) = delete;

			DescriptorPool(GPU& gpu, Pipeline& pipeline,uint32_t numObjects);
			~DescriptorPool();
			const VkDescriptorSet* getDescriptorSets(uint32_t currentFrame,uint32_t index) { return &descriptorSets[currentFrame*numObjects+index]; }
			void updateUniformBuffer(UniformBufferObject ubo, uint32_t currentImage, uint32_t index);
			VkDescriptorPool getDescriptorPool() { return descriptorPool; }
		private:
			GPU& gpu;
			uint32_t numObjects;
			VkDescriptorPool descriptorPool;
			VkDescriptorSetLayout descriptorSetLayout;
			std::vector<VkDescriptorSet> descriptorSets;
			std::vector<std::unique_ptr<Buffer>> uniformBuffers{MAX_FRAMES_IN_FLIGHT * numObjects};

			void createDescriptorPool();
			void createDescriptorSets(Pipeline& pipeline);
			void createUniformBuffers();
		};

	}
	
}

