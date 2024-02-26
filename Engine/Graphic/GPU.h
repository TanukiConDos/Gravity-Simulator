#pragma once

#define NOMINMAX

#include<vulkan/vulkan.hpp>
#define VK_USE_PLATFORM_WIN32_KHR
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#define GLM_FORCE_RADIANS
#define GLM_FORCE_DEPTH_ZERO_TO_ONE
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <chrono>
#include <iostream>
#include <optional>
#include <set>
#include <cstdint>
#include <limits>
#include <algorithm>
#include <map>

#include "../../Application/Window.h"
#include "Graphic.h"

namespace Engine
{
	namespace Graphic
	{
		const std::vector<const char*> deviceExtensions = {
		VK_KHR_SWAPCHAIN_EXTENSION_NAME
		};

		class GPU
		{
		public:

			GPU(const GPU&) = delete;
			GPU& operator=(const GPU&) = delete;

			~GPU();
			GPU(Application::Window& window);
			GPU() = default;
			void wait();
			VkDevice getDevice() { return device; }
			VkPhysicalDevice getPhysicalDevice() { return physicalDevice; }
			SwapChainSupportDetails querySwapChainSupport() { return querySwapChainSupport(physicalDevice); }
			QueueFamilyIndices findQueueFamilies() { return findQueueFamilies(physicalDevice); }
			void createBuffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties, VkBuffer& buffer, VkDeviceMemory& bufferMemory);
			void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size, VkCommandBuffer commandBuffer);
			VkQueue getGraphicsQueue() { return graphicsQueue; }
			VkQueue getPresentQueue() { return presentQueue; }
			uint32_t findMemoryType(uint32_t typeFilter, VkMemoryPropertyFlags properties);
		private:
			VkInstance instance;
			VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
			VkDevice device;
			VkQueue graphicsQueue;
			VkQueue presentQueue;
			Application::Window& window;

			void createInstance();
			void pickPhysicalDevice();
			void createLogicalDevice();
			bool checkDeviceExtensionSupport(VkPhysicalDevice device);
			SwapChainSupportDetails querySwapChainSupport(VkPhysicalDevice device);
			bool rateDeviceSuitability(VkPhysicalDevice device);
			QueueFamilyIndices findQueueFamilies(VkPhysicalDevice device);
		};
	}
}

