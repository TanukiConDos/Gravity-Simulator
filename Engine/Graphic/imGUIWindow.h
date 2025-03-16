/**
 * @file imGUIWindow.h
 * @brief Integra ImGui en la aplicación, gestionando la interfaz gráfica. 
 *
 * La clase ImGUIWindow inicializa y configura ImGui con GLFW y Vulkan, interactuando 
 * con la ventana, GPU, SwapChain, Pipeline y DescriptorPool. Además, utiliza la máquina 
 * de estados de la aplicación para actualizar la interfaz y dispone de un pool de descriptores 
 * (_imguiPool) para renderizar la UI.
 */

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

namespace Engine::Graphic
{
	/**
		* @class ImGUIWindow
		* @brief Gestiona la interfaz gráfica basada en ImGui.
		*
		* Esta clase inicializa ImGui, configura la integración con GLFW y Vulkan, 
		* y ofrece métodos para iniciar el frame de ImGui y dibujar la interfaz sobre 
		* un VkCommandBuffer.
		*/
	class ImGUIWindow
	{
	public:
		ImGUIWindow(const ImGUIWindow&) = delete;
		ImGUIWindow& operator=(const ImGUIWindow&) = delete;

		/**
			* @brief Constructor.
			*
			* Inicializa ImGui utilizando la ventana, GPU, SwapChain, Pipeline y la instancia Vulkan.
			* Además, recibe punteros a variables de tiempo para frame y tick, que pueden ser mostradas en la UI.
			*
			* @param window Referencia a la ventana de la aplicación.
			* @param gpu Referencia a la instancia de GPU.
			* @param swapChain Referencia al SwapChain.
			* @param pipeline Referencia al Pipeline.
			* @param instance Instancia Vulkan.
			* @param frameTime Puntero a la variable de tiempo de frame.
			* @param tickTime Puntero a la variable de tiempo de tick.
			*/
		ImGUIWindow(Application::Window& window, GPU& gpu, SwapChain& swapChain, Pipeline& pipeline, VkInstance instance, float* frameTime, float* tickTime);
			
		/**
			* @brief Destructor.
			*
			* Libera los recursos utilizados por ImGui.
			*/
		~ImGUIWindow();

		/**
			* @brief Inicia el frame de ImGui.
			*
			* Prepara a ImGui para comenzar a registrar los elementos de la interfaz para el frame actual.
			*/
		void startFrame();

		/**
			* @brief Renderiza la interfaz ImGui.
			*
			* Dibuja el contenido de ImGui en el VkCommandBuffer proporcionado.
			*
			* @param commandBuffer Buffer de comandos donde se dibuja la UI.
			*/
		void draw(VkCommandBuffer commandBuffer);
	private:
		/// Máquina de estados de la aplicación.
		std::shared_ptr<Application::StateMachine> _stateMachine = Application::StateMachine::getStateMachine();
		/// Pool de descriptores utilizado por ImGui.
		VkDescriptorPool _imguiPool;
	};
}


