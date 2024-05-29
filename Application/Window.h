#pragma once
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#include <stdexcept>
#include "input.h"

namespace Application
{
	class Window
	{
	public:
		
		~Window();

		Window(int width, int height);
		Window() = default;
		Window(const Window&) = delete;
		Window& operator=(const Window&) = delete;
		static void framebufferResizeCallback(GLFWwindow* window, int width, int height);
		static void key_callback(GLFWwindow* window, int key, int scancode, int action, int mods);
		VkSurfaceKHR getSurface() { return surface; }

		GLFWwindow* getWindow();
		bool getFramebufferResized() { return framebufferResized; }
		void setFramebufferResized() { framebufferResized = false; }
		void checkMinimized();
		void getSize(int& width, int& height);
		void createSurface(VkInstance instance);
		void attachCameraToEvent(Engine::Graphic::Camera* camera) { inputEvent.subscribe(camera); }
	private:
		GLFWwindow* window;
		bool framebufferResized = false;
		int width, height;
		VkSurfaceKHR surface;
		InputEvent inputEvent{};
	};
}
