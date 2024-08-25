#include "DescriptorPool.h"
namespace Engine::Graphic
{
	DescriptorPool::DescriptorPool(GPU& gpu,Pipeline& pipeline,uint32_t numObjects): _gpu(gpu), _numObjects(numObjects)
	{
		createDescriptorPool();
		createUniformBuffers();
		createDescriptorSets(pipeline);
	}

	DescriptorPool::~DescriptorPool()
	{
		vkDestroyDescriptorPool(_gpu.getDevice(), _descriptorPool, nullptr);
		vkDestroyDescriptorSetLayout(_gpu.getDevice(), _descriptorSetLayout, nullptr);
	}

	void DescriptorPool::createDescriptorPool()
	{
		VkDescriptorPoolSize poolSize{};
		poolSize.type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
		poolSize.descriptorCount = static_cast<uint32_t>(MAX_FRAMES_IN_FLIGHT) * _numObjects;

		VkDescriptorPoolCreateInfo poolInfo{};
		poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
		poolInfo.poolSizeCount = 1;
		poolInfo.pPoolSizes = &poolSize;
		poolInfo.maxSets = static_cast<uint32_t>(MAX_FRAMES_IN_FLIGHT) * _numObjects;

		if (vkCreateDescriptorPool(_gpu.getDevice(), &poolInfo, nullptr, &_descriptorPool) != VK_SUCCESS) {
			throw std::runtime_error("failed to create descriptor pool!");
		}
	}

	void DescriptorPool::createDescriptorSets(Pipeline& pipeline)
	{
		std::vector<VkDescriptorSetLayout> layouts(MAX_FRAMES_IN_FLIGHT*_numObjects, pipeline.getDescriptorSetLayout());

		VkDescriptorSetAllocateInfo allocInfo{};
		allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
		allocInfo.descriptorPool = _descriptorPool;
		allocInfo.descriptorSetCount = static_cast<uint32_t>(MAX_FRAMES_IN_FLIGHT) * _numObjects;
		allocInfo.pSetLayouts = layouts.data();

		_descriptorSets.resize(MAX_FRAMES_IN_FLIGHT*_numObjects);
		if (vkAllocateDescriptorSets(_gpu.getDevice(), &allocInfo, _descriptorSets.data()) != VK_SUCCESS) {
			throw std::runtime_error("failed to allocate descriptor sets!");
		}

		for (size_t i = 0; i < MAX_FRAMES_IN_FLIGHT * _numObjects; i++) {
			VkDescriptorBufferInfo bufferInfo{};
			bufferInfo.buffer = _uniformBuffers[i]->getBuffer();
			bufferInfo.offset = 0;
			bufferInfo.range = sizeof(UniformBufferObject);

			VkWriteDescriptorSet descriptorWrite{};
			descriptorWrite.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
			descriptorWrite.dstSet = _descriptorSets[i];
			descriptorWrite.dstBinding = 0;
			descriptorWrite.dstArrayElement = 0;
			descriptorWrite.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
			descriptorWrite.descriptorCount = 1;
			descriptorWrite.pBufferInfo = &bufferInfo;
			descriptorWrite.pImageInfo = nullptr; // Optional
			descriptorWrite.pTexelBufferView = nullptr; // Optional

			vkUpdateDescriptorSets(_gpu.getDevice(), 1, &descriptorWrite, 0, nullptr);
		}
	}

	void DescriptorPool::updateUniformBuffer(UniformBufferObject ubo,uint32_t currentImage,uint32_t index)
	{
		ubo.proj[1][1] *= -1;

		_uniformBuffers[currentImage * _numObjects + index]->writeData(&ubo, sizeof(ubo));
	}

	void DescriptorPool::createUniformBuffers()
	{
		VkDeviceSize bufferSize = sizeof(UniformBufferObject);
		for (size_t i = 0; i < MAX_FRAMES_IN_FLIGHT * _numObjects; i++) {
			
			_uniformBuffers[i] = std::make_unique<Buffer>(_gpu,bufferSize,VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

			_uniformBuffers[i]->map();
		}
	}
}