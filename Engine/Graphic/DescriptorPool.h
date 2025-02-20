/**
 * @file DescriptorPool.h
 * @brief Gestiona los conjuntos de descriptores para buffers uniformes y la configuraci�n del pipeline gr�fico.
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
		 * y los buffers uniformes asociados al pipeline gr�fico.
		 */
		class DescriptorPool
		{
		public:
			DescriptorPool(const DescriptorPool&) = delete;
			DescriptorPool& operator=(const DescriptorPool&) = delete;

			/**
			 * @brief Constructor que inicializa el DescriptorPool.
			 * @param gpu Referencia a la instancia de GPU.
			 * @param pipeline Referencia al pipeline gr�fico.
			 * @param numObjects N�mero de objetos para los que se gestionar�n buffers uniformes.
			 */
			DescriptorPool(GPU& gpu, Pipeline& pipeline, uint32_t numObjects);

			/**
			 * @brief Destructor que libera los recursos asignados.
			 */
			~DescriptorPool();

			/**
			 * @brief Obtiene el conjunto de descriptores correspondiente al frame y al �ndice especificados.
			 * @param currentFrame �ndice del frame actual.
			 * @param index �ndice del objeto.
			 * @return const VkDescriptorSet* Puntero al conjunto de descriptores.
			 */
			const VkDescriptorSet* getDescriptorSets(uint32_t currentFrame, uint32_t index) { return &_descriptorSets[currentFrame * _numObjects + index]; }

			/**
			 * @brief Actualiza el buffer uniforme asociado a un conjunto de descriptores espec�fico.
			 * @param ubo Objeto de buffer uniforme con la informaci�n de transformaci�n.
			 * @param currentImage �ndice de la imagen actual.
			 * @param index �ndice del objeto.
			 */
			void updateUniformBuffer(UniformBufferObject ubo, uint32_t currentImage, uint32_t index);

			/**
			 * @brief Obtiene el pool de descriptores.
			 * @return VkDescriptorPool Pool de descriptores.
			 */
			VkDescriptorPool getDescriptorPool() { return _descriptorPool; }
		private:
			/// Referencia a la instancia de GPU.
			GPU& _gpu;
			/// N�mero de objetos gestionados.
			uint32_t _numObjects;
			/// Pool de descriptores de Vulkan.
			VkDescriptorPool _descriptorPool;
			/// Layout del descriptor set.
			VkDescriptorSetLayout _descriptorSetLayout;
			/// Vector con los conjuntos de descriptores.
			std::vector<VkDescriptorSet> _descriptorSets;
			/// Buffers uniformes, uno para cada objeto y frame.
			std::vector<std::unique_ptr<Buffer>> _uniformBuffers{ MAX_FRAMES_IN_FLIGHT * _numObjects };

			/**
			 * @brief Crea el pool de descriptores.
			 */
			void createDescriptorPool();
			
			/**
			 * @brief Crea los conjuntos de descriptores utilizando el pipeline gr�fico.
			 * @param pipeline Referencia al pipeline gr�fico.
			 */
			void createDescriptorSets(Pipeline& pipeline);
			
			/**
			 * @brief Crea los buffers uniformes.
			 */
			void createUniformBuffers();
		};
	}
}

