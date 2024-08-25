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
            app->_inputEvent.submit(InputAction::MOVE_FORWARD);
            break;
        case GLFW_KEY_A:
            app->_inputEvent.submit(InputAction::MOVE_LEFT_SIDE);
            break;
        case GLFW_KEY_S:
            app->_inputEvent.submit(InputAction::MOVE_BACKWARD);
            break;
        case GLFW_KEY_D:
            app->_inputEvent.submit(InputAction::MOVE_RIGHT_SIDE);
            break;
        case GLFW_KEY_Q:
            app->_inputEvent.submit(InputAction::MOVE_DOWN);
            break;

        case GLFW_KEY_E:
            app->_inputEvent.submit(InputAction::MOVE_UP);
            break;
        case GLFW_KEY_UP:
            app->_inputEvent.submit(InputAction::ROTATE_UP);
            break;
        case GLFW_KEY_DOWN:
            app->_inputEvent.submit(InputAction::ROTATE_DOWN);
            break;
        case GLFW_KEY_LEFT:
            app->_inputEvent.submit(InputAction::ROTATE_LEFT);
            break;
        case GLFW_KEY_RIGHT:
            app->_inputEvent.submit(InputAction::ROTATE_RIGHT);
            break;
        default:

            break;
        }
    }

    Window::~Window()
    {
        glfwDestroyWindow(_window);
        glfwTerminate();
    }

    Window::Window(int width, int height): _width(width), _height(height)
    {
        glfwInit();

        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);

       _window = glfwCreateWindow(width, height, "Vulkan", nullptr, nullptr);

        glfwSetWindowUserPointer(_window, this);
        glfwSetFramebufferSizeCallback(_window, framebufferResizeCallback);
        glfwSetKeyCallback(_window, key_callback);
    }

    void Window::framebufferResizeCallback(GLFWwindow* window, int width, int height)
    {
        auto app = reinterpret_cast<Window*>(glfwGetWindowUserPointer(window));
        app->_framebufferResized = true;
    }

    GLFWwindow* Window::getWindow()
    {
        return _window;
    }
    void Window::checkMinimized()
    {
        glfwGetFramebufferSize(_window, &_width, &_height);
        while (_width == 0 || _height == 0) {
            glfwGetFramebufferSize(_window, &_width, &_height);
            glfwWaitEvents();
        }
    }
    void Window::getSize(int& width, int& height)
    {
        width = this->_width;
        height = this->_height;
    }
    void Window::createSurface(VkInstance instace)
    {
        if (glfwCreateWindowSurface(instace, _window, nullptr, &_surface) != VK_SUCCESS) {
            throw std::runtime_error("failed to create window surface!");
        }
    }
}