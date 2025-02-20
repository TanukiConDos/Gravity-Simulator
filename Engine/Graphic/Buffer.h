/**
 * @file Buffer.h
 * @brief Gestiona los buffers de Vulkan, permitiendo la creación, mapeo y escritura de datos.
 */

#pragma once
#include "vulkan/vulkan.hpp"
#include "GPU.h"

namespace Engine
{
	namespace Graphic
	{
		/**
		 * @class Buffer
		 * @brief Clase para la gestión de buffers de Vulkan.
		 *
		 * Esta clase se encarga de crear un buffer en la GPU, mapear su memoria y escribir datos en él.
		 */
		class Buffer
		{
		public:
			Buffer(const Buffer&) = delete;
			Buffer& operator=(const Buffer&) = delete;
			Buffer& operator= (Buffer&&) = default;
			Buffer(Buffer&&) = default;

			/// Constructor por defecto.
			Buffer() = default;
			/**
			 * @brief Crea un buffer de Vulkan.
			 *
			 * Inicializa el buffer utilizando la GPU, definiendo el tamaño de la instancia, las banderas de uso
			 * y las propiedades de memoria.
			 *
			 * @param gpu Referencia a la GPU.
			 * @param instanceSize Tamaño del buffer.
			 * @param usageFlags Banderas de uso del buffer.
			 * @param memoryPropertyFlags Propiedades de la memoria.
			 */
			Buffer(GPU& gpu, VkDeviceSize instanceSize, VkBufferUsageFlags usageFlags, VkMemoryPropertyFlags memoryPropertyFlags);
			
			/**
			 * @brief Destructor.
			 *
			 * Libera los recursos asociados al buffer.
			 */
			~Buffer();
			
			/**
			 * @brief Mapea la memoria del buffer.
			 *
			 * Permite acceder a la memoria del buffer para escribir datos.
			 *
			 * @param size Tamaño a mapear, por defecto VK_WHOLE_SIZE.
			 * @param offset Desplazamiento desde el inicio, por defecto 0.
			 * @return VkResult Resultado de la operación de mapeo.
			 */
			VkResult map(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
			
			/**
			 * @brief Escribe datos en el buffer mapeado.
			 *
			 * Copia la información proporcionada a la memoria del buffer.
			 *
			 * @param data Puntero a los datos a escribir.
			 * @param size Tamaño de los datos, por defecto VK_WHOLE_SIZE.
			 * @param offset Desplazamiento donde iniciar la escritura, por defecto 0.
			 */
			void writeData(void* data, VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);

			/**
			 * @brief Obtiene el handle del buffer de Vulkan.
			 *
			 * @return VkBuffer Handle del buffer.
			 */
			VkBuffer getBuffer() const { return _buffer; }
		private:
			/// Referencia a la GPU utilizada para crear el buffer.
			GPU& _gpu;
			/// Handle del buffer de Vulkan.
			VkBuffer _buffer = VK_NULL_HANDLE;
			/// Memoria asignada al buffer.
			VkDeviceMemory _bufferMemory = VK_NULL_HANDLE;
			/// Tamaño del buffer.
			VkDeviceSize _bufferSize;
			/// Puntero a la memoria mapeada del buffer.
			void* _mappedData = nullptr;
		};
	}
}


