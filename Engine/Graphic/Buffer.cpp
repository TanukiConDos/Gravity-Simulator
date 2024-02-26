#include "Buffer.h"

namespace Engine
{
	namespace Graphic
	{
		Buffer::Buffer(GPU& gpu, VkDeviceSize instanceSize, VkBufferUsageFlags usageFlags, VkMemoryPropertyFlags memoryPropertyFlags): gpu(gpu), bufferSize(instanceSize)
		{
			gpu.createBuffer(instanceSize, usageFlags, memoryPropertyFlags, buffer, bufferMemory);
		}
		Buffer::~Buffer()
		{
			if (mappedData != nullptr)
			{
				vkUnmapMemory(gpu.getDevice(), bufferMemory);
				mappedData = nullptr;
			}
			vkDestroyBuffer(gpu.getDevice(), buffer, nullptr);
			vkFreeMemory(gpu.getDevice(), bufferMemory, nullptr);

		}
		VkResult Buffer::map(VkDeviceSize size, VkDeviceSize offset)
		{
			return vkMapMemory(gpu.getDevice(), bufferMemory, 0, size, 0, &mappedData);
		}

		void Buffer::writeData(void* data, VkDeviceSize size, VkDeviceSize offset)
		{
			if (size == VK_WHOLE_SIZE)
			{
				memcpy(mappedData, data, size);
			}
			else
			{
				char* memOffset = (char*)mappedData;
				memOffset += offset;
				memcpy(memOffset, data, size);
			}
			
		}
	}
}