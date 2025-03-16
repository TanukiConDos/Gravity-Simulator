#include "Renderer.h"

namespace Engine::Graphic
{
	Renderer::Renderer(Application::Window& window, std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> physicObjects,float* frameTime, float* tickTime) : _window(window), _physicObjects(physicObjects), _frameTime(frameTime),_tickTime(tickTime)
	{
		for (int i = 0; i < physicObjects->size(); i++)
		{
			_gameObjects[i] = UniformBufferObject{};
		}
	}

	void Renderer::updateObjects()
	{
		_descriptorPool = std::make_unique<DescriptorPool>(_gpu, _pipeline, static_cast<uint32_t>(_physicObjects->size()));
		_gameObjects.resize(_physicObjects->size());
		for (int i = 0; i < _physicObjects->size(); i++)
		{
			_gameObjects[i] = UniformBufferObject{};
		}
	}

	void Renderer::drawFrame()
	{
		VkResult result = _swapChain.adquireNextImage(_currentFrame);
		if (result == VK_ERROR_OUT_OF_DATE_KHR) {
			_swapChain.recreateSwapChain();
			return;
		}
		else if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
			throw std::runtime_error("failed to acquire swap chain image!");
		}


		_swapChain.resetFences(_currentFrame);

		_commandPool.resetCommandBuffer(_currentFrame);
		VkCommandBuffer commandBuffer = _commandPool.beginCommandBuffer(_currentFrame);

		_swapChain.beginRenderPass(commandBuffer, _currentFrame);
		_pipeline.bind(commandBuffer);
		_imGui.startFrame();
		for (int i = 0; i < _gameObjects.size(); i++)
		{
			_gameObjects[i].updateModel(_physicObjects->at(i));
			_camera.transform(_gameObjects[i]);
			_descriptorPool->updateUniformBuffer(_gameObjects[i], _currentFrame,i);
			vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, _pipeline.getPipelineLayout(), 0, 1, _descriptorPool->getDescriptorSets(_currentFrame,i), 0, nullptr);
			_model.bind(commandBuffer);
			vkCmdDrawIndexed(commandBuffer, static_cast<uint32_t>(_model.getIndexSize()), 1, 0, 0, 0);
		}
		if(!_gameObjects.empty()) _descriptorPool->sendUniformBufferToGPU(_currentFrame);
		_imGui.draw(commandBuffer);
		vkCmdEndRenderPass(commandBuffer);

		_commandPool.endCommandBuffer(commandBuffer);

		_swapChain.queueSubmit(commandBuffer, _currentFrame);


		if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR || _window.getFramebufferResized()) {
			_window.setFramebufferResized();
			_swapChain.recreateSwapChain();
			return;
		}
		else if (result != VK_SUCCESS) {
			throw std::runtime_error("failed to present swap chain image!");
		}

		_currentFrame = (_currentFrame + 1) % MAX_FRAMES_IN_FLIGHT;
	}
}