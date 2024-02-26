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
			VkExtent2D getExtent() { return swapChainExtent; }
			VkResult queueSubmit(VkCommandBuffer commandBuffer, uint32_t currentFrame);
			VkRenderPass getRenderPass() { return renderPass; }
		private:
			GPU& gpu;
			Application::Window& window;
			VkSwapchainKHR swapChain = VK_NULL_HANDLE;
			VkSwapchainKHR oldSwapchain = VK_NULL_HANDLE;
			std::vector<VkImage> swapChainImages;
			VkFormat swapChainImageFormat;
			VkExtent2D swapChainExtent;
			std::vector<VkImageView> swapChainImageViews;
			VkRenderPass renderPass;
			std::vector<VkFramebuffer> swapChainFramebuffers;
			VkImage depthImage;
			VkDeviceMemory depthImageMemory;
			VkImageView depthImageView;
			std::vector<VkSemaphore> imageAvailableSemaphores;
			std::vector<VkSemaphore> renderFinishedSemaphores;
			std::vector<VkFence> inFlightFences;

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


