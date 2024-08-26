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
		VkSurfaceKHR getSurface() { return _surface; }

		GLFWwindow* getWindow();
		bool getFramebufferResized() const { return _framebufferResized; }
		void setFramebufferResized() { _framebufferResized = false; }
		void checkMinimized();
		void getSize(int& width, int& height);
		void createSurface(VkInstance instance);
		void attachCameraToEvent(Engine::Graphic::Camera* camera) { _inputEvent.subscribe(camera); }
	private:
		GLFWwindow* _window;
		bool _framebufferResized = false;
		int _width;
		int _height;
		VkSurfaceKHR _surface;
		InputEvent _inputEvent{};
	};
}
