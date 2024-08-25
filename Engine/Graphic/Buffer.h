#pragma once
#include "vulkan/vulkan.hpp"
#include "GPU.h"
namespace Engine
{
	namespace Graphic
	{
		class Buffer
		{
		public:
			Buffer(const Buffer&) = delete;
			Buffer& operator=(const Buffer&) = delete;
			Buffer& operator= (Buffer&&) = default;
			Buffer(Buffer&&) = default;

			Buffer() = default;
			Buffer(GPU& gpu, VkDeviceSize instanceSize, VkBufferUsageFlags usageFlags, VkMemoryPropertyFlags memoryPropertyFlags);
			~Buffer();
			VkResult map(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
			void writeData(void* data, VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);

			VkBuffer getBuffer() const { return _buffer; }
		private:
			GPU& _gpu;
			VkBuffer _buffer = VK_NULL_HANDLE;
			VkDeviceMemory _bufferMemory = VK_NULL_HANDLE;
			VkDeviceSize _bufferSize;
			void* _mappedData = nullptr;
		};
	}
}


