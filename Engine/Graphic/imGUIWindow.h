#pragma once
#include "../../External/imgui/imgui.h"
#include "../../External/imgui/imgui_impl_glfw.h"
#include "../../External/imgui/imgui_impl_vulkan.h"
#include "../../Application/Window.h"
#include "../../Application/State.h"
#include "GPU.h"
#include "Pipeline.h"
#include "DescriptorPool.h"
#include "SwapChain.h"

namespace Engine
{
	namespace Graphic
	{
		class ImGUIWindow
		{
		public:
			ImGUIWindow(const ImGUIWindow&) = delete;
			ImGUIWindow& operator=(const ImGUIWindow&) = delete;
			ImGUIWindow(Application::Window& window,GPU& gpu,SwapChain& swapChain,Pipeline& pipeline, VkInstance instance, float* frameTime, float* tickTime);
			~ImGUIWindow();

			void startFrame();
			void draw(VkCommandBuffer commandBuffer);
		private:
			std::shared_ptr<Application::StateMachine> _stateMachine = Application::StateMachine::getStateMachine();
			VkDescriptorPool _imguiPool;
			
		};
	}
}


