#pragma once
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>


namespace Application
{
	class Window
	{
	public:
		~Window();

		Window(int width, int height);
		Window() = default;
		static void framebufferResizeCallback(GLFWwindow* window, int width, int height);

		GLFWwindow* getWindow();
		bool getFramebufferResized() { return framebufferResized; }
		void setFramebufferResized() { framebufferResized = false; }
		void checkMinimized();
		void getSize(int& width, int& height);
		
	private:
		GLFWwindow* window;
		bool framebufferResized = false;
		int width, height;
	};
}
