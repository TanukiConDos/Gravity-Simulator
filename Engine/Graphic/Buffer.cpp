#include "Buffer.h"

namespace Engine
{
	namespace Graphic
	{
		Buffer::Buffer(GPU& gpu, VkDeviceSize instanceSize, VkBufferUsageFlags usageFlags, VkMemoryPropertyFlags memoryPropertyFlags): _gpu(gpu), _bufferSize(instanceSize)
		{
			gpu.createBuffer(instanceSize, usageFlags, memoryPropertyFlags, _buffer, _bufferMemory);
		}
		Buffer::~Buffer()
		{
			if (_mappedData != nullptr)
			{
				vkUnmapMemory(_gpu.getDevice(), _bufferMemory);
				_mappedData = nullptr;
			}
			vkDestroyBuffer(_gpu.getDevice(), _buffer, nullptr);
			vkFreeMemory(_gpu.getDevice(), _bufferMemory, nullptr);

		}
		VkResult Buffer::map(VkDeviceSize size, VkDeviceSize offset)
		{
			return vkMapMemory(_gpu.getDevice(), _bufferMemory, 0, size, 0, &_mappedData);
		}

		void Buffer::writeData(void* data, VkDeviceSize size, VkDeviceSize offset)
		{
			if (size == VK_WHOLE_SIZE)
			{
				memcpy(_mappedData, data, size);
			}
			else
			{
				char* memOffset = (char*)_mappedData;
				memOffset += offset;
				memcpy(memOffset, data, size);
			}
			
		}
	}
}