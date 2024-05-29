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

			~Renderer();
			Renderer(Application::Window& window, std::shared_ptr<std::vector<Engine::Physic::PhysicObject*>>& physicObjects,float& frameTime,float& tickTime);
			void updateObjects();
			void drawFrame();
			void wait() { gpu.wait(); }
			Camera* getCamera() { return &camera; }

		private:
			Application::Window& window;
			GPU gpu = GPU{window};
			CommandPool commandPool = CommandPool{gpu};
			SwapChain swapChain = SwapChain{gpu,window};
			Pipeline pipeline = Pipeline{ gpu,swapChain.getRenderPass() };
			std::shared_ptr<std::vector<Engine::Physic::PhysicObject*>>& physicObjects;
			std::vector<UniformBufferObject> gameObjects = std::vector<UniformBufferObject>{physicObjects->size()};
			DescriptorPool* descriptorPool = new DescriptorPool(gpu, pipeline, static_cast<uint32_t>(physicObjects->size()));
			Model model = Model{30,30,gpu,commandPool};
			float& frameTime;
			float& tickTime;
			ImGUIWindow imGui = ImGUIWindow{ window, gpu, swapChain, pipeline, gpu.getInstance(),frameTime,tickTime};
			
			Camera camera = Camera{swapChain};
			uint32_t currentFrame = 0;
		};
	}
}


