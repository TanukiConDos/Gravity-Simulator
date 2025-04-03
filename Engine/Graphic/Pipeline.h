/**
 * @file Pipeline.h
 * @brief Gestiona la creación y configuración del pipeline gráfico de Vulkan.
 */

#pragma once
#include <vulkan/vulkan.hpp>
#include "../../Foundation/File.h"
#include "GPU.h"

namespace Engine::Graphic
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

		struct PipelineConfig
		{
			std::string vertexShaderPath = "./Engine/Graphic/shader/vert.spv";
			std::string fragmentShaderPath = "./Engine/Graphic/shader/frag.spv";

			VkPipelineShaderStageCreateInfo vertexShaderStageInfo{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
				.stage = VK_SHADER_STAGE_VERTEX_BIT,
				.pName = "main"
			};
			VkPipelineShaderStageCreateInfo fragmentShaderStageInfo{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
				.stage = VK_SHADER_STAGE_FRAGMENT_BIT,
				.pName = "main"
			};
			VkPipelineVertexInputStateCreateInfo vertexInputInfo{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
				.vertexBindingDescriptionCount = 1
			};
			VkPipelineInputAssemblyStateCreateInfo inputAssembly{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
				.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
				.primitiveRestartEnable = VK_FALSE
			};
			VkPipelineDynamicStateCreateInfo dynamicState{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
			};
			VkPipelineViewportStateCreateInfo viewportState{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
				.viewportCount = 1,
				.scissorCount = 1
			};
			VkPipelineDepthStencilStateCreateInfo depthStencil{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
				.depthTestEnable = VK_TRUE,
				.depthWriteEnable = VK_TRUE,
				.depthCompareOp = VK_COMPARE_OP_LESS,
				.depthBoundsTestEnable = VK_FALSE,
				.stencilTestEnable = VK_FALSE,
				.front = {},
				.back = {},
				.minDepthBounds = 0.0f,
				.maxDepthBounds = 1.0f,
			};
			VkPipelineRasterizationStateCreateInfo rasterizer{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
				.depthClampEnable = VK_FALSE,
				.rasterizerDiscardEnable = VK_FALSE,
				.polygonMode = VK_POLYGON_MODE_FILL,
				.cullMode = VK_CULL_MODE_BACK_BIT,
				.frontFace = VK_FRONT_FACE_CLOCKWISE,
				.depthBiasEnable = VK_FALSE,
				.depthBiasConstantFactor = 0.0f,
				.depthBiasClamp = 0.0f,
				.depthBiasSlopeFactor = 0.0f,
				.lineWidth = 1.0f,
			};
			VkPipelineMultisampleStateCreateInfo multisampling{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
				.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
				.sampleShadingEnable = VK_FALSE,
				.minSampleShading = 1.0f,
				.pSampleMask = nullptr,
				.alphaToCoverageEnable = VK_FALSE,
				.alphaToOneEnable = VK_FALSE
			};
			VkPipelineColorBlendAttachmentState colorBlendAttachment{
				.blendEnable = VK_FALSE,
				.srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
				.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO,
				.colorBlendOp = VK_BLEND_OP_ADD,
				.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
				.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
				.alphaBlendOp = VK_BLEND_OP_ADD,
				.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT
			};
			VkPipelineColorBlendStateCreateInfo colorBlending{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
				.logicOpEnable = VK_FALSE,
				.logicOp = VK_LOGIC_OP_COPY,
				.attachmentCount = 1,
				.pAttachments = &colorBlendAttachment,
				.blendConstants = { 0.0f, 0.0f, 0.0f, 0.0f }
			};
			VkPipelineLayoutCreateInfo pipelineLayoutInfo{
				.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
				.setLayoutCount = 1,
				.pushConstantRangeCount = 0,
				.pPushConstantRanges = nullptr
			};
			VkGraphicsPipelineCreateInfo pipelineInfo{
				.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
				.stageCount = 2,
				.pVertexInputState = &vertexInputInfo,
				.pInputAssemblyState = &inputAssembly,
				.pViewportState = &viewportState,
				.pRasterizationState = &rasterizer,
				.pMultisampleState = &multisampling,
				.pDepthStencilState = &depthStencil,
				.pColorBlendState = &colorBlending,
				.pDynamicState = &dynamicState,
				.basePipelineHandle = VK_NULL_HANDLE,
				.basePipelineIndex = -1
			};
		} _pipelineConfig;

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

