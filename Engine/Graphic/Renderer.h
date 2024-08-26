#pragma once
#include <vulkan/vulkan.hpp>

#include <iostream>
#include <memory>
#include "../../Application/Window.h"
#include "../Physic/PhysicObject.h"
#include "GPU.h"
#include "CommandPool.h"
#include "SwapChain.h"
#include "Pipeline.h"
#include "Model.h"
#include "DescriptorPool.h"
#include "Camera.h"
#include "imGUIWindow.h"

namespace Engine
{
	namespace Graphic
	{
		class Renderer
		{
		public:

			Renderer(const Renderer&) = delete;
			Renderer& operator=(const Renderer&) = delete;

			Renderer(Application::Window& window, std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> physicObjects,float* frameTime,float* tickTime);
			void updateObjects();
			void drawFrame();
			void wait() { _gpu.wait(); }
			Camera* getCamera() { return &_camera; }

		private:
			Application::Window& _window;
			GPU _gpu = GPU{_window};
			CommandPool _commandPool = CommandPool{_gpu};
			SwapChain _swapChain = SwapChain{_gpu,_window};
			Pipeline _pipeline = Pipeline{ _gpu,_swapChain.getRenderPass() };
			std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _physicObjects;
			std::vector<UniformBufferObject> _gameObjects = std::vector<UniformBufferObject>{_physicObjects->size()};
			std::unique_ptr<DescriptorPool> _descriptorPool =  std::make_unique<DescriptorPool>(_gpu, _pipeline, static_cast<uint32_t>(_physicObjects->size()));
			Model _model = Model{30,30,_gpu,_commandPool};
			float* _frameTime;
			float* _tickTime;
			ImGUIWindow _imGui = ImGUIWindow{ _window, _gpu, _swapChain, _pipeline, _gpu.getInstance(),_frameTime,_tickTime};
			
			Camera _camera = Camera{_swapChain};
			uint32_t _currentFrame = 0;
		};
	}
}


