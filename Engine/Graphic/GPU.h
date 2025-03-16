/**
 * @file GPU.h
 * @brief Gestiona los recursos de la GPU y la interacci�n con Vulkan, utilizando la ventana provista.
 */

#pragma once

#define NOMINMAX

#include <vulkan/vulkan.hpp>
#define VK_USE_PLATFORM_WIN32_KHR
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#define GLM_FORCE_RADIANS
#define GLM_FORCE_DEPTH_ZERO_TO_ONE
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <chrono>
#include <iostream>
#include <optional>
#include <set>
#include <cstdint>
#include <limits>
#include <algorithm>
#include <map>

#include "../../Application/Window.h"
#include "Graphic.h"

namespace Engine::Graphic
{
	/**
		* @brief Extensiones requeridas para el dispositivo.
		*/
	const std::vector<const char*> deviceExtensions = {
		VK_KHR_SWAPCHAIN_EXTENSION_NAME
	};

	/**
		* @class GPU
		* @brief Clase que administra recursos de la GPU y la interacci�n con Vulkan.
		*
		* Se encarga de crear la instancia Vulkan, seleccionar el dispositivo f�sico,
		* crear el dispositivo l�gico, construir los buffers y gestionar las colas
		* de gr�ficos y presentaci�n, usando la ventana proporcionada.
		*/
	class GPU
	{
	public:
		GPU(const GPU&) = delete;
		GPU& operator=(const GPU&) = delete;

		/**
			* @brief Destructor.
			*/
		~GPU();
		/**
			* @brief Constructor que inicializa la GPU con la ventana especificada.
			* @param window Referencia a la ventana de la aplicaci�n.
			*/
		explicit GPU(Application::Window& window);

		/**
			* @brief Espera a que se completen las operaciones en la GPU.
			*/
		void wait();
		/**
			* @brief Obtiene la instancia Vulkan.
			* @return VkInstance Instancia Vulkan.
			*/
		VkInstance getInstance() { return _instance; }
		/**
			* @brief Obtiene el dispositivo l�gico.
			* @return VkDevice Dispositivo l�gico.
			*/
		VkDevice getDevice() { return _device; }
		/**
			* @brief Obtiene el dispositivo f�sico.
			* @return VkPhysicalDevice Dispositivo f�sico seleccionado.
			*/
		VkPhysicalDevice getPhysicalDevice() { return _physicalDevice; }
		/**
			* @brief Consulta el soporte del swap chain para el dispositivo.
			* @return SwapChainSupportDetails Detalles de soporte.
			*/
		SwapChainSupportDetails querySwapChainSupport() { return querySwapChainSupport(_physicalDevice); }
		/**
			* @brief Encuentra los �ndices de las familias de colas para el dispositivo.
			* @return QueueFamilyIndices �ndices encontrados.
			*/
		QueueFamilyIndices findQueueFamilies() { return findQueueFamilies(_physicalDevice); }
		/**
			* @brief Crea un buffer en la GPU.
			* @param size Tama�o del buffer.
			* @param usage Uso del buffer.
			* @param properties Propiedades de la memoria.
			* @param buffer Referencia para almacenar el buffer creado.
			* @param bufferMemory Referencia para almacenar la memoria asignada.
			*/
		void createBuffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties, VkBuffer& buffer, VkDeviceMemory& bufferMemory);
		/**
			* @brief Copia datos entre buffers en la GPU.
			* @param srcBuffer Buffer origen.
			* @param dstBuffer Buffer destino.
			* @param size Tama�o de la copia.
			* @param commandBuffer Buffer de comando para la operaci�n de copia.
			*/
		void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size, VkCommandBuffer commandBuffer);
		/**
			* @brief Obtiene la cola de gr�ficos.
			* @return VkQueue Cola de gr�ficos.
			*/
		VkQueue getGraphicsQueue() { return _graphicsQueue; }
		/**
			* @brief Obtiene la cola de presentaci�n.
			* @return VkQueue Cola de presentaci�n.
			*/
		VkQueue getPresentQueue() { return _presentQueue; }
		/**
			* @brief Encuentra el �ndice del tipo de memoria adecuado.
			* @param typeFilter Filtro del tipo.
			* @param properties Propiedades requeridas.
			* @return uint32_t �ndice del tipo de memoria.
			*/
		uint32_t findMemoryType(uint32_t typeFilter, VkMemoryPropertyFlags properties);
	private:
		/// Instancia Vulkan.
		VkInstance _instance;
		/// Dispositivo f�sico.
		VkPhysicalDevice _physicalDevice = VK_NULL_HANDLE;
		/// Dispositivo l�gico.
		VkDevice _device;
		/// Cola de gr�ficos.
		VkQueue _graphicsQueue;
		/// Cola de presentaci�n.
		VkQueue _presentQueue;
		/// Referencia a la ventana utilizada.
		Application::Window& _window;

		/**
			* @brief Crea la instancia Vulkan.
			*/
		void createInstance();
		/**
			* @brief Selecciona el dispositivo f�sico �ptimo.
			*/
		void pickPhysicalDevice();
		/**
			* @brief Crea el dispositivo l�gico.
			*/
		void createLogicalDevice();
		/**
			* @brief Verifica si el dispositivo f�sico soporta las extensiones requeridas.
			* @param device Dispositivo a verificar.
			* @return true si soporta las extensiones, false de lo contrario.
			*/
		bool checkDeviceExtensionSupport(VkPhysicalDevice device);
		/**
			* @brief Consulta el soporte del swap chain para el dispositivo especificado.
			* @param device Dispositivo f�sico.
			* @return SwapChainSupportDetails Detalles del soporte del swap chain.
			*/
		SwapChainSupportDetails querySwapChainSupport(VkPhysicalDevice device);
		/**
			* @brief Eval�a la idoneidad del dispositivo f�sico.
			* @param device Dispositivo a evaluar.
			* @return true si el dispositivo es adecuado, false en caso contrario.
			*/
		bool rateDeviceSuitability(VkPhysicalDevice device);
		/**
			* @brief Encuentra los �ndices de las familias de colas para el dispositivo.
			* @param device Dispositivo f�sico.
			* @return QueueFamilyIndices �ndices de las familias de colas.
			*/
		QueueFamilyIndices findQueueFamilies(VkPhysicalDevice device);
	};
}

