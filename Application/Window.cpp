#include "Window.h"


namespace Application
{
    void Window::key_callback(GLFWwindow* window, int key, int scancode, int action, int mods)
    {
        if (action == GLFW_RELEASE) return;
        auto app = reinterpret_cast<Window*>(glfwGetWindowUserPointer(window));
        switch (key)
        {
        case GLFW_KEY_W:
            app->inputEvent.submit(InputAction::MOVE_FORWARD);
            break;
        case GLFW_KEY_A:
            app->inputEvent.submit(InputAction::MOVE_LEFT_SIDE);
            break;
        case GLFW_KEY_S:
            app->inputEvent.submit(InputAction::MOVE_BACKWARD);
            break;
        case GLFW_KEY_D:
            app->inputEvent.submit(InputAction::MOVE_RIGHT_SIDE);
            break;
        case GLFW_KEY_Q:
            app->inputEvent.submit(InputAction::MOVE_DOWN);
            break;

        case GLFW_KEY_E:
            app->inputEvent.submit(InputAction::MOVE_UP);
            break;
        case GLFW_KEY_UP:
            app->inputEvent.submit(InputAction::ROTATE_UP);
            break;
        case GLFW_KEY_DOWN:
            app->inputEvent.submit(InputAction::ROTATE_DOWN);
            break;
        case GLFW_KEY_LEFT:
            app->inputEvent.submit(InputAction::ROTATE_LEFT);
            break;
        case GLFW_KEY_RIGHT:
            app->inputEvent.submit(InputAction::ROTATE_RIGHT);
            break;
        default:

            break;
        }
    }

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
        glfwSetKeyCallback(window, key_callback);
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
    void Window::createSurface(VkInstance instace)
    {
        if (glfwCreateWindowSurface(instace, window, nullptr, &surface) != VK_SUCCESS) {
            throw std::runtime_error("failed to create window surface!");
        }
    }
}