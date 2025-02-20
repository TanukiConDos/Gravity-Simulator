/**
 * @file Pipeline.h
 * @brief Gestiona la creación y configuración del pipeline gráfico de Vulkan.
 */

#pragma once
#include <vulkan/vulkan.hpp>
#include "../../Foundation/File.h"
#include "GPU.h"

namespace Engine
{
	namespace Graphic
	{
		/**
		 * @class Pipeline
		 * @brief Clase encargada de construir y gestionar el pipeline gráfico de Vulkan.
		 *
		 * Esta clase se encarga de crear el pipeline gráfico utilizando la GPU y un render pass proporcionado.
		 * Además, configura el layout de descriptor sets y el pipeline layout.
		 */
		class Pipeline
		{
		public:
			Pipeline(const Pipeline&) = delete;
			Pipeline& operator=(const Pipeline&) = delete;

			/**
			 * @brief Constructor que inicializa el pipeline gráfico.
			 *
			 * Inicializa el pipeline utilizando la GPU y el render pass, configurando los estados dinámicos y layouts.
			 *
			 * @param gpu Referencia a la GPU.
			 * @param renderPass Render pass utilizado para la creación del pipeline.
			 */
			Pipeline(GPU& gpu, VkRenderPass renderPass);
			
			/**
			 * @brief Destructor.
			 *
			 * Libera los recursos asociados al pipeline gráfico.
			 */
			~Pipeline();
			
			/**
			 * @brief Enlaza el pipeline gráfico al buffer de comandos.
			 *
			 * Este método vincula el pipeline al buffer de comandos para su utilización en la renderización.
			 *
			 * @param commandBuffer Buffer de comandos donde se enlaza el pipeline.
			 */
			void bind(VkCommandBuffer commandBuffer);
			
			/**
			 * @brief Obtiene el layout del descriptor set.
			 *
			 * @return VkDescriptorSetLayout Layout del descriptor set.
			 */
			VkDescriptorSetLayout getDescriptorSetLayout() { return _descriptorSetLayout; }
			
			/**
			 * @brief Obtiene el pipeline layout.
			 *
			 * @return VkPipelineLayout Layout del pipeline.
			 */
			VkPipelineLayout getPipelineLayout() { return _pipelineLayout; }
		private:
			/// Referencia a la GPU utilizada para la creación del pipeline.
			GPU& _gpu;
			/// Layout del pipeline.
			VkPipelineLayout _pipelineLayout;
			/// Pipeline gráfico de Vulkan.
			VkPipeline _graphicsPipeline;
			/// Layout del descriptor set.
			VkDescriptorSetLayout _descriptorSetLayout;
			/// Estados dinámicos utilizados en el pipeline.
			const std::vector<VkDynamicState> _dynamicStates = {
				VK_DYNAMIC_STATE_VIEWPORT,
				VK_DYNAMIC_STATE_SCISSOR
			};

			/**
			 * @brief Crea un módulo de shader a partir del código proporcionado.
			 *
			 * @param code Vector de bytes que contiene el código del shader.
			 * @return VkShaderModule Módulo de shader creado.
			 */
			VkShaderModule createShaderModule(const std::vector<char>& code);
			
			/**
			 * @brief Crea el layout para los descriptor sets.
			 *
			 * Configura el layout de descriptores utilizando el dispositivo lógico.
			 *
			 * @param device Dispositivo lógico de Vulkan.
			 */
			void createDescriptorSetLayout(VkDevice device);
		};
	}
}

