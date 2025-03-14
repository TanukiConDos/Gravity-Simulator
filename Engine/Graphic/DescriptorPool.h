/**
 * @file DescriptorPool.h
 * @brief Gestiona los conjuntos de descriptores para buffers uniformes y la configuración del pipeline gráfico.
 */

#pragma once
#include <vulkan/vulkan.hpp>
#include "GPU.h"
#include "Pipeline.h"
#include "Buffer.h"

namespace Engine
{
	namespace Graphic
	{
		/**
		 * @class DescriptorPool
		 * @brief Clase que crea y administra el pool de descriptores, los conjuntos de descriptores 
		 * y los buffers uniformes asociados al pipeline gráfico.
		 */
		class DescriptorPool
		{
		public:
			DescriptorPool(const DescriptorPool&) = delete;
			DescriptorPool& operator=(const DescriptorPool&) = delete;

			/**
			 * @brief Constructor que inicializa el DescriptorPool.
			 * @param gpu Referencia a la instancia de GPU.
			 * @param pipeline Referencia al pipeline gráfico.
			 * @param numObjects Número de objetos para los que se gestionarán buffers uniformes.
			 */
			DescriptorPool(GPU& gpu, Pipeline& pipeline, uint32_t numObjects);

			/**
			 * @brief Destructor que libera los recursos asignados.
			 */
			~DescriptorPool();

			/**
			 * @brief Obtiene el conjunto de descriptores correspondiente al frame y al índice especificados.
			 * @param currentFrame Índice del frame actual.
			 * @param index Índice del objeto.
			 * @return const VkDescriptorSet* Puntero al conjunto de descriptores.
			 */
			const VkDescriptorSet* getDescriptorSets(uint32_t currentFrame, uint32_t index) { return &_descriptorSets[currentFrame*_numObjects+index]; }

			/**
			 * @brief Actualiza el buffer uniforme asociado a un conjunto de descriptores específico.
			 * @param ubo Objeto de buffer uniforme con la información de transformación.
			 * @param currentImage Índice de la imagen actual.
			 * @param index Índice del objeto.
			 */
			void updateUniformBuffer(UniformBufferObject ubo, uint32_t currentImage, uint32_t index);

			void sendUniformBufferToGPU(uint32_t currentImage);

			/**
			 * @brief Obtiene el pool de descriptores.
			 * @return VkDescriptorPool Pool de descriptores.
			 */
			VkDescriptorPool getDescriptorPool() { return _descriptorPool; }
		private:
			/// Referencia a la instancia de GPU.
			GPU& _gpu;
			/// Número de objetos gestionados.
            /**
             * @brief Envía los buffers uniformes a la GPU.
             *
             * Este método transfiere el contenido actualizado de los buffers uniformes de la imagen actual a la GPU.
             * Esto asegura que los datos de transformación y otros parámetros uniformes se encuentren sincronizados 
             * con el procesamiento gráfico del frame correspondiente.
             *
             * @param currentImage Índice de la imagen actual para la que se deben enviar los datos.
             */
            void sendUniformBufferToGPU(uint32_t currentImage);
			uint32_t _numObjects;
			/// Pool de descriptores de Vulkan.
			VkDescriptorPool _descriptorPool;
			/// Layout del descriptor set.
			VkDescriptorSetLayout _descriptorSetLayout;
			/// Vector con los conjuntos de descriptores.
			std::vector<VkDescriptorSet> _descriptorSets;
			/// Buffers uniformes, uno para cada frame.
			std::vector<std::unique_ptr<Buffer>> _uniformBuffers{ MAX_FRAMES_IN_FLIGHT };

			/**
			 * @brief Crea el pool de descriptores.
			 */
			void createDescriptorPool();
			
			/**
			 * @brief Crea los conjuntos de descriptores utilizando el pipeline gráfico.
			 * @param pipeline Referencia al pipeline gráfico.
			 */
			void createDescriptorSets(Pipeline& pipeline);
			
			/**
			 * @brief Crea los buffers uniformes.
			 */
			void createUniformBuffers();
		};
	}
}

