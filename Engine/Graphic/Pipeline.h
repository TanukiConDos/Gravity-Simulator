/**
 * @file Pipeline.h
 * @brief Gestiona la creaci�n y configuraci�n del pipeline gr�fico de Vulkan.
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
		 * @brief Clase encargada de construir y gestionar el pipeline gr�fico de Vulkan.
		 *
		 * Esta clase se encarga de crear el pipeline gr�fico utilizando la GPU y un render pass proporcionado.
		 * Adem�s, configura el layout de descriptor sets y el pipeline layout.
		 */
		class Pipeline
		{
		public:
			Pipeline(const Pipeline&) = delete;
			Pipeline& operator=(const Pipeline&) = delete;

			/**
			 * @brief Constructor que inicializa el pipeline gr�fico.
			 *
			 * Inicializa el pipeline utilizando la GPU y el render pass, configurando los estados din�micos y layouts.
			 *
			 * @param gpu Referencia a la GPU.
			 * @param renderPass Render pass utilizado para la creaci�n del pipeline.
			 */
			Pipeline(GPU& gpu, VkRenderPass renderPass);
			
			/**
			 * @brief Destructor.
			 *
			 * Libera los recursos asociados al pipeline gr�fico.
			 */
			~Pipeline();
			
			/**
			 * @brief Enlaza el pipeline gr�fico al buffer de comandos.
			 *
			 * Este m�todo vincula el pipeline al buffer de comandos para su utilizaci�n en la renderizaci�n.
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
			/// Referencia a la GPU utilizada para la creaci�n del pipeline.
			GPU& _gpu;
			/// Layout del pipeline.
			VkPipelineLayout _pipelineLayout;
			/// Pipeline gr�fico de Vulkan.
			VkPipeline _graphicsPipeline;
			/// Layout del descriptor set.
			VkDescriptorSetLayout _descriptorSetLayout;
			/// Estados din�micos utilizados en el pipeline.
			const std::vector<VkDynamicState> _dynamicStates = {
				VK_DYNAMIC_STATE_VIEWPORT,
				VK_DYNAMIC_STATE_SCISSOR
			};

			/**
			 * @brief Crea un m�dulo de shader a partir del c�digo proporcionado.
			 *
			 * @param code Vector de bytes que contiene el c�digo del shader.
			 * @return VkShaderModule M�dulo de shader creado.
			 */
			VkShaderModule createShaderModule(const std::vector<char>& code);
			
			/**
			 * @brief Crea el layout para los descriptor sets.
			 *
			 * Configura el layout de descriptores utilizando el dispositivo l�gico.
			 *
			 * @param device Dispositivo l�gico de Vulkan.
			 */
			void createDescriptorSetLayout(VkDevice device);
		};
	}
}

