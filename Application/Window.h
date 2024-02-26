#pragma once
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#include <stdexcept>

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
		VkSurfaceKHR getSurface() { return surface; }

		GLFWwindow* getWindow();
		bool getFramebufferResized() { return framebufferResized; }
		void setFramebufferResized() { framebufferResized = false; }
		void checkMinimized();
		void getSize(int& width, int& height);
		void createSurface(VkInstance instance);

	private:
		GLFWwindow* window;
		bool framebufferResized = false;
		int width, height;
		VkSurfaceKHR surface;
	};
}
