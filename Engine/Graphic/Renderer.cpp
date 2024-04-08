#include "Renderer.h"

namespace Engine
{
	namespace Graphic
	{
		Renderer::~Renderer()
		{	
		}

		Renderer::Renderer(Application::Window& window, std::shared_ptr<std::vector<Engine::Physic::PhysicObject*>>& physicObjects,float& frameTime, float& tickTime) : window(window), physicObjects(physicObjects), frameTime(frameTime),tickTime(tickTime)
		{
			for (int i = 0; i < physicObjects->size(); i++)
			{
				gameObjects[i] = UniformBufferObject{};
			}
		}

		void Renderer::drawFrame()
		{
			VkResult result = swapChain.adquireNextImage(currentFrame);
			if (result == VK_ERROR_OUT_OF_DATE_KHR) {
				swapChain.recreateSwapChain();
				return;
			}
			else if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
				throw std::runtime_error("failed to acquire swap chain image!");
			}


			swapChain.resetFences(currentFrame);

			commandPool.resetCommandBuffer(currentFrame);
			VkCommandBuffer commandBuffer = commandPool.beginCommandBuffer(currentFrame);

			swapChain.beginRenderPass(commandBuffer, currentFrame);
			pipeline.bind(commandBuffer);
			imGui.startFrame();
			for (int i = 0; i < gameObjects.size(); i++)
			{
				gameObjects[i].updateModel(*physicObjects->at(i));
				camera.transform(gameObjects[i]);
				descriptorPool.updateUniformBuffer(gameObjects[i], currentFrame,i);
				vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.getPipelineLayout(), 0, 1, descriptorPool.getDescriptorSets(currentFrame,i), 0, nullptr);
				model.bind(commandBuffer);
				vkCmdDrawIndexed(commandBuffer, static_cast<uint32_t>(model.getIndexSize()), 1, 0, 0, 0);
			}
			imGui.draw(commandBuffer);
			vkCmdEndRenderPass(commandBuffer);

			commandPool.endCommandBuffer(commandBuffer);

			swapChain.queueSubmit(commandBuffer, currentFrame);


			if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR || window.getFramebufferResized()) {
				window.setFramebufferResized();
				swapChain.recreateSwapChain();
				return;
			}
			else if (result != VK_SUCCESS) {
				throw std::runtime_error("failed to present swap chain image!");
			}

			currentFrame = (currentFrame + 1) % MAX_FRAMES_IN_FLIGHT;
		}
	}
}

