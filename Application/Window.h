/**
 * @file Window.h
 * @brief Define la clase Window para gestionar la ventana y sus eventos.
 */

#pragma once
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#include <stdexcept>
#include "input.h"

namespace Application
{
/**
 * @class Window
 * @brief Clase que gestiona la ventana y sus eventos.
 */
    class Window {
    public:
        /**
         * @brief Constructor por defecto.
         */
        Window();

        /**
         * @brief Constructor que crea la ventana con dimensiones específicas.
         * 
         * @param width Ancho de la ventana.
         * @param height Alto de la ventana.
         */
        Window(int width, int height);

        /**
         * @brief Destructor.
         */
        ~Window();

        Window(const Window&) = delete;
		Window& operator=(const Window&) = delete;

        /**
         * @brief Callback para el redimensionado del framebuffer.
         *
         * @param window Puntero a la ventana GLFW.
         * @param width Nuevo ancho.
         * @param height Nuevo alto.
         */
        static void framebufferResizeCallback(GLFWwindow* window, int width, int height);

        /**
         * @brief Callback para eventos de teclado.
         *
         * @param window Puntero a la ventana GLFW.
         * @param key Código de la tecla.
         * @param scancode Código de escaneo.
         * @param action Acción del evento.
         * @param mods Modificadores.
         */
        static void keyCallback(GLFWwindow* window, int key, int scancode, int action, int mods);

        /**
         * @brief Obtiene la superficie Vulkan asociada a la ventana.
         * 
         * @return VkSurfaceKHR Superficie Vulkan.
         */
        VkSurfaceKHR getSurface() { return _surface; }

        GLFWwindow* getWindow();

        /**
         * @brief Indica si el framebuffer ha sido redimensionado.
         * 
         * @return true si se produjo un cambio, false en caso contrario.
         */
        bool getFramebufferResized() const { return _framebufferResized; }



        /**
         * @brief Marca la ventana como redimensionada.
         */
        void setFramebufferResized() { _framebufferResized = false; }

        /**
         * @brief Comprueba si la ventana está minimizada.
         */
        void checkMinimized();

        /**
         * @brief Obtiene el tamaño actual de la ventana.
         *
         * @param width Referencia al ancho.
         * @param height Referencia al alto.
         */
        void getSize(int& width, int& height);

        /**
         * @brief Crea la superficie Vulkan de la ventana.
         *
         * @param instance Instancia de Vulkan.
         */
        void createSurface(VkInstance instance);

        /**
         * @brief Asocia una cámara a los eventos de entrada.
         *
         * @param camera Puntero a la cámara.
         */
        void attachCameraToEvent(Engine::Graphic::Camera* camera) { _inputEvent.subscribe(camera); }

    private:
        /// Puntero a la ventana GLFW.
        GLFWwindow* _window;
        /// Indica si se ha redimensionado el framebuffer.
        bool _framebufferResized = false;
        /// Ancho de la ventana.
        int _width;
        /// Alto de la ventana.
        int _height;
        /// Superficie Vulkan asociada.
        VkSurfaceKHR _surface;
        /// Evento de entrada.
        InputEvent _inputEvent{};
    };
}
