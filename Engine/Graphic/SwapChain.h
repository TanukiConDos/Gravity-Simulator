#pragma once
#include <vulkan/vulkan.hpp>
#include "../../Application/Window.h"
#include "GPU.h"

namespace Engine
{
	namespace Graphic
	{
		class SwapChain
		{
		public:

			SwapChain(const SwapChain&) = delete;
			SwapChain& operator= (const SwapChain&) = delete;

			SwapChain(GPU& gpu, Application::Window& window);
			~SwapChain();

			void recreateSwapChain();
			VkResult adquireNextImage(uint32_t imageIndex);
			void resetFences(uint32_t currentFrame);
			void beginRenderPass(VkCommandBuffer commandBuffer, uint32_t imageIndex);
			VkExtent2D getExtent() const { return _swapChainExtent; }
			VkResult queueSubmit(VkCommandBuffer commandBuffer, uint32_t currentFrame);
			VkRenderPass getRenderPass() const { return _renderPass; }
		private:
			GPU& _gpu;
			Application::Window& _window;
			VkSwapchainKHR _swapChain = VK_NULL_HANDLE;
			VkSwapchainKHR _oldSwapchain = VK_NULL_HANDLE;
			std::vector<VkImage> _swapChainImages;
			VkFormat _swapChainImageFormat;
			VkExtent2D _swapChainExtent;
			std::vector<VkImageView> _swapChainImageViews;
			VkRenderPass _renderPass;
			std::vector<VkFramebuffer> _swapChainFramebuffers;
			VkImage _depthImage;
			VkDeviceMemory _depthImageMemory;
			VkImageView _depthImageView;
			std::vector<VkSemaphore> _imageAvailableSemaphores;
			std::vector<VkSemaphore> _renderFinishedSemaphores;
			std::vector<VkFence> _inFlightFences;

			VkExtent2D chooseSwapExtent(const VkSurfaceCapabilitiesKHR& capabilities);
			VkPresentModeKHR chooseSwapPresentMode(const std::vector<VkPresentModeKHR>& availablePresentModes);
			VkSurfaceFormatKHR chooseSwapSurfaceFormat(const std::vector<VkSurfaceFormatKHR>& availableFormats);

			void createSwapChain();
			void createImageViews();
			void cleanupSwapChain();
			VkImageView createImageView(VkImage image, VkFormat format, VkImageAspectFlags aspectFlags);
			void createImage(uint32_t width, uint32_t height, VkFormat format, VkImageTiling tiling, VkImageUsageFlags usage, VkMemoryPropertyFlags properties, VkImage& image, VkDeviceMemory& imageMemory);
			VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
			void createDepthResources();

			void createRenderPass();
			void createFramebuffers();
			VkFormat findDepthFormat();
			bool hasStencilComponent(VkFormat format);
			void createSyncObjects();
		};
	}
	
}


