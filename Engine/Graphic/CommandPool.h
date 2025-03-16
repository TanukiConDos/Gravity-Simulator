/**
 * @file CommandPool.h
 * @brief Gestiona la creaci�n y administraci�n de un pool de comandos para la GPU.
 *
 * Este archivo encapsula un VkCommandPool y administra m�ltiples VkCommandBuffer. Se proveen m�todos para iniciar,
 * finalizar y reinicializar buffers de comandos utilizados en la renderizaci�n y sincronizaci�n en Vulkan.
 */

#pragma once
#include <vulkan/vulkan.hpp>
#include "Graphic.h"
#include "GPU.h"
#include "Pipeline.h"

namespace Engine::Graphic
{
	/**
		* @class CommandPool
		* @brief Encapsula un pool de comandos de Vulkan y gestiona m�ltiples buffers de comando.
		*
		* La clase utiliza una referencia a GPU para crear el VkCommandPool, y ofrece m�todos para administrar la
		* creaci�n, inicio, finalizaci�n y reinicializaci�n de VkCommandBuffer.
		*/
	class CommandPool
	{
	public:
		CommandPool(const CommandPool&) = delete;
		CommandPool& operator=(const CommandPool&) = delete;

		/**
			* @brief Constructor que inicializa el pool de comandos.
			*
			* Utiliza la referencia a la GPU para crear el pool de comandos mediante createCommandPool().
			*
			* @param gpu Referencia a la GPU que se utiliza para crear el pool de comandos.
			*/
		explicit CommandPool(GPU& gpu);

		/**
			* @brief Destructor.
			*
			* Libera los recursos asociados al pool de comandos.
			*/
		~CommandPool();

		/**
			* @brief Inicia un buffer de comandos para la imagen especificada.
			*
			* Crea y comienza la grabaci�n de un VkCommandBuffer que se utilizar� para la renderizaci�n de la imagen.
			*
			* @param imageIndex �ndice de la imagen para el cual se inicia el comando.
			* @return VkCommandBuffer Buffer de comandos iniciado.
			*/
		VkCommandBuffer beginCommandBuffer(uint32_t imageIndex);

		/**
			* @brief Finaliza el registro en un buffer de comandos.
			*
			* Este m�todo finaliza la grabaci�n del VkCommandBuffer proporcionado.
			*
			* @param commandBuffer Buffer de comandos a finalizar.
			*/
		void endCommandBuffer(VkCommandBuffer commandBuffer) const;

		/**
			* @brief Reinicializa el buffer de comandos para el frame actual.
			*
			* Este m�todo reinicia el estado del buffer de comando asociado al frame indicado, permitiendo su reutilizaci�n.
			*
			* @param currentFrame �ndice del frame actual.
			*/
		void resetCommandBuffer(uint32_t currentFrame);

		/**
			* @brief Crea un buffer de comandos temporal.
			*
			* Este m�todo crea un VkCommandBuffer destinado a operaciones temporales.
			*
			* @return VkCommandBuffer Buffer de comandos temporal.
			*/
		VkCommandBuffer createTemporalCommandBuffer();

		/**
			* @brief Finaliza un buffer de comandos temporal.
			*
			* Este m�todo finaliza la grabaci�n en un buffer de comandos temporal.
			*
			* @param commandBuffer Buffer de comandos temporal a finalizar.
			*/
		void endTemporalCommandBuffer(VkCommandBuffer commandBuffer);
			
	private:
		/// Referencia a la GPU utilizada para crear el pool de comandos.
		GPU& _gpu;
		/// Pool de comandos de Vulkan.
		VkCommandPool _commandPool;
		/// Vector de buffers de comando asociados al pool.
		std::vector<VkCommandBuffer> _commandBuffers;

		/**
			* @brief Crea el pool de comandos.
			*
			* Inicializa el VkCommandPool utilizando la GPU.
			*/
		void createCommandPool();

		/**
			* @brief Crea los buffers de comandos asociados al pool.
			*
			* Inicializa y configura los VkCommandBuffer asociados al VkCommandPool.
			*/
		void createCommandBuffer();
			
	};
}
