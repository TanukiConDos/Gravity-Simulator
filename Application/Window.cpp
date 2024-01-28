#include "Window.h"

namespace Application
{

    Window::~Window()
    {
        glfwDestroyWindow(window);
        glfwTerminate();
    }

    Window::Window(int width, int height): width(width), height(height)
    {
        glfwInit();

        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);

        window = glfwCreateWindow(width, height, "Vulkan", nullptr, nullptr);

        glfwSetWindowUserPointer(window, this);
        glfwSetFramebufferSizeCallback(window, framebufferResizeCallback);
    }

    void Window::framebufferResizeCallback(GLFWwindow* window, int width, int height)
    {
        auto app = reinterpret_cast<Window*>(glfwGetWindowUserPointer(window));
        app->framebufferResized = true;
    }
    GLFWwindow* Window::getWindow()
    {
        return window;
    }
    void Window::checkMinimized()
    {
        glfwGetFramebufferSize(window, &width, &height);
        while (width == 0 || height == 0) {
            glfwGetFramebufferSize(window, &width, &height);
            glfwWaitEvents();
        }
    }
    void Window::getSize(int& width, int& height)
    {
        width = this->width;
        height = this->height;
    }
}