/**
 * @file Renderer.h
 * @brief Define la clase Renderer, encargada de gestionar la renderizaci�n utilizando Vulkan.
 */
#pragma once
#include <vulkan/vulkan.hpp>

#include <iostream>
#include <memory>
#include "../../Application/Window.h"
#include "../Physic/PhysicObject.h"
#include "GPU.h"
#include "CommandPool.h"
#include "SwapChain.h"
#include "Pipeline.h"
#include "Model.h"
#include "DescriptorPool.h"
#include "Camera.h"
#include "imGUIWindow.h"

 /**
  * @namespace Engine::Graphic
  * @brief Espacio de nombres que contiene las clases del motor gr�fico.
  */
namespace Engine::Graphic
{
	/**
		* @class Renderer
		* @brief Clase encargada de gestionar la renderizaci�n y actualizaci�n de la escena utilizando Vulkan.
		*
		* Esta clase coordina la ventana, GPU, pool de comandos, swap chain, pipeline gr�fico, 
		* actualizaci�n de objetos f�sicos, uniformes, descriptor pool, modelo, interfaz ImGUI y c�mara.
		*/
	class Renderer
	{
	public:
		Renderer(const Renderer&) = delete;
		Renderer& operator=(const Renderer&) = delete;

		/**
			* @brief Constructor de Renderer.
			*
			* Inicializa la renderizaci�n con la ventana especificada, la colecci�n de objetos f�sicos, y
			* punteros a las variables de tiempo de frame y tick.
			*
			* @param window Referencia a la ventana de la aplicaci�n.
			* @param physicObjects Puntero compartido a la colecci�n de objetos f�sicos.
			* @param frameTime Puntero al tiempo de frame.
			* @param tickTime Puntero al tiempo de tick.
			*/
		Renderer(Application::Window& window, std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> physicObjects, float* frameTime, float* tickTime);

		/**
			* @brief Actualiza la informaci�n de los objetos a renderizar.
			*/
		void updateObjects();

		/**
			* @brief Dibuja un frame, actualizando la renderizaci�n de la escena.
			*/
		void drawFrame();

		/**
			* @brief Espera a que se completen las operaciones en la GPU.
			*/
		void wait() { _gpu.wait(); }

		/**
			* @brief Obtiene la c�mara utilizada para la renderizaci�n.
			* @return Puntero a la c�mara.
			*/
		Camera* getCamera() { return &_camera; }

	private:
		/// Referencia a la ventana de la aplicaci�n.
		Application::Window& _window;
		/// Instancia de la GPU que gestiona la interacci�n con Vulkan.
		GPU _gpu = GPU{ _window };
		/// Pool de comandos para enviar �rdenes a la GPU.
		CommandPool _commandPool = CommandPool{ _gpu };
		/// SwapChain que gestiona el intercambio de im�genes.
		SwapChain _swapChain = SwapChain{ _gpu, _window };
		/// Pipeline gr�fico para la renderizaci�n.
		Pipeline _pipeline = Pipeline{ _gpu, _swapChain.getRenderPass() };
		/// Colecci�n de objetos f�sicos de la simulaci�n.
		std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _physicObjects;
		/// Vector de objetos uniformes, uno por objeto f�sico.
		std::vector<UniformBufferObject> _gameObjects = std::vector<UniformBufferObject>{ _physicObjects->size() };
		/// Pool de descriptores para manejar uniform buffers.
		std::unique_ptr<DescriptorPool> _descriptorPool = std::make_unique<DescriptorPool>(_gpu, _pipeline, static_cast<uint32_t>(_physicObjects->size()));
		/// Modelo que representa la geometr�a y v�rtices.
		Model _model = Model{ 30,30,_gpu,_commandPool };
		/// Puntero al tiempo de frame.
		float* _frameTime;
		/// Puntero al tiempo de tick.
		float* _tickTime;
		/// tiempo acumulado para la actualizaci�n de objetos.
		float _time = 0.0f;
		/// Interfaz de usuario ImGui para herramientas y depuraci�n.
		ImGUIWindow _imGui = ImGUIWindow{ _window, _gpu, _swapChain, _pipeline, _gpu.getInstance(), _frameTime, _tickTime };
		/// C�mara utilizada para la visualizaci�n de la escena.
		Camera _camera = Camera{ _swapChain };
		/// �ndice del frame actual.
		uint32_t _currentFrame = 0;
	};
}

