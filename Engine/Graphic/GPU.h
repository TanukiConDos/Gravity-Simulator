/**
 * @file GPU.h
 * @brief Gestiona los recursos de la GPU y la interacción con Vulkan, utilizando la ventana provista.
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
		* @brief Clase que administra recursos de la GPU y la interacción con Vulkan.
		*
		* Se encarga de crear la instancia Vulkan, seleccionar el dispositivo físico,
		* crear el dispositivo lógico, construir los buffers y gestionar las colas
		* de gráficos y presentación, usando la ventana proporcionada.
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
			* @param window Referencia a la ventana de la aplicación.
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
			* @brief Obtiene el dispositivo lógico.
			* @return VkDevice Dispositivo lógico.
			*/
		VkDevice getDevice() { return _device; }
		/**
			* @brief Obtiene el dispositivo físico.
			* @return VkPhysicalDevice Dispositivo físico seleccionado.
			*/
		VkPhysicalDevice getPhysicalDevice() { return _physicalDevice; }
		/**
			* @brief Consulta el soporte del swap chain para el dispositivo.
			* @return SwapChainSupportDetails Detalles de soporte.
			*/
		SwapChainSupportDetails querySwapChainSupport() { return querySwapChainSupport(_physicalDevice); }
		/**
			* @brief Encuentra los índices de las familias de colas para el dispositivo.
			* @return QueueFamilyIndices Índices encontrados.
			*/
		QueueFamilyIndices findQueueFamilies() { return findQueueFamilies(_physicalDevice); }
		/**
			* @brief Crea un buffer en la GPU.
			* @param size Tamaño del buffer.
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
			* @param size Tamaño de la copia.
			* @param commandBuffer Buffer de comando para la operación de copia.
			*/
		void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size, VkCommandBuffer commandBuffer);
		/**
			* @brief Obtiene la cola de gráficos.
			* @return VkQueue Cola de gráficos.
			*/
		VkQueue getGraphicsQueue() { return _graphicsQueue; }
		/**
			* @brief Obtiene la cola de presentación.
			* @return VkQueue Cola de presentación.
			*/
		VkQueue getPresentQueue() { return _presentQueue; }
		/**
			* @brief Encuentra el índice del tipo de memoria adecuado.
			* @param typeFilter Filtro del tipo.
			* @param properties Propiedades requeridas.
			* @return uint32_t Índice del tipo de memoria.
			*/
		uint32_t findMemoryType(uint32_t typeFilter, VkMemoryPropertyFlags properties);
	private:
		/// Instancia Vulkan.
		VkInstance _instance;
		/// Dispositivo físico.
		VkPhysicalDevice _physicalDevice = VK_NULL_HANDLE;
		/// Dispositivo lógico.
		VkDevice _device;
		/// Cola de gráficos.
		VkQueue _graphicsQueue;
		/// Cola de presentación.
		VkQueue _presentQueue;
		/// Referencia a la ventana utilizada.
		Application::Window& _window;

		/**
			* @brief Crea la instancia Vulkan.
			*/
		void createInstance();
		/**
			* @brief Selecciona el dispositivo físico óptimo.
			*/
		void pickPhysicalDevice();
		/**
			* @brief Crea el dispositivo lógico.
			*/
		void createLogicalDevice();
		/**
			* @brief Verifica si el dispositivo físico soporta las extensiones requeridas.
			* @param device Dispositivo a verificar.
			* @return true si soporta las extensiones, false de lo contrario.
			*/
		bool checkDeviceExtensionSupport(VkPhysicalDevice device);
		/**
			* @brief Consulta el soporte del swap chain para el dispositivo especificado.
			* @param device Dispositivo físico.
			* @return SwapChainSupportDetails Detalles del soporte del swap chain.
			*/
		SwapChainSupportDetails querySwapChainSupport(VkPhysicalDevice device);
		/**
			* @brief Evalúa la idoneidad del dispositivo físico.
			* @param device Dispositivo a evaluar.
			* @return true si el dispositivo es adecuado, false en caso contrario.
			*/
		bool rateDeviceSuitability(VkPhysicalDevice device);
		/**
			* @brief Encuentra los índices de las familias de colas para el dispositivo.
			* @param device Dispositivo físico.
			* @return QueueFamilyIndices Índices de las familias de colas.
			*/
		QueueFamilyIndices findQueueFamilies(VkPhysicalDevice device);
	};
}

