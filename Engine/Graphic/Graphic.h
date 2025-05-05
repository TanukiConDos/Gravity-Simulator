/**
 * @file Graphic.h
 * @brief Define las estructuras y constantes utilizadas en la gesti�n de recursos gr�ficos con Vulkan.
 */

#pragma once
#include <vulkan/vulkan.hpp>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <optional>
#include <vector>
#include "../Physic/PhysicObject.h"

namespace Engine::Graphic
{
	/// N�mero m�ximo de frames en vuelo.
	const int MAX_FRAMES_IN_FLIGHT = 1;

	/**
		* @struct QueueFamilyIndices
		* @brief Almacena los �ndices de las familias de colas para gr�ficos y presentaci�n.
		*/
	struct QueueFamilyIndices {
		/// �ndice de la familia de colas de gr�ficos.
		std::optional<uint32_t> graphicsFamily;
		/// �ndice de la familia de colas de presentaci�n.
		std::optional<uint32_t> presentFamily;

		/**
			* @brief Comprueba si se han definido los �ndices necesarios.
			* @return true si graphicsFamily tiene valor.
			*/
		bool isComplete() const {
			return graphicsFamily.has_value();
		}
	};

	/**
		* @struct SwapChainSupportDetails
		* @brief Almacena informaci�n sobre el soporte del swap chain.
		*/
	struct SwapChainSupportDetails {
		/// Capacidades de la superficie.
		VkSurfaceCapabilitiesKHR capabilities;
		/// Lista de formatos de superficie disponibles.
		std::vector<VkSurfaceFormatKHR> formats;
		/// Lista de modos de presentaci�n disponibles.
		std::vector<VkPresentModeKHR> presentModes;
	};

	/**
		* @struct UniformBufferObject
		* @brief Estructura utilizada para almacenar las matrices de transformaci�n y estado de selecci�n.
		*/
	struct UniformBufferObject {
		/// Matriz de modelo.
		alignas(16) glm::mat4 model;
		/// Matriz de vista.
		alignas(16) glm::mat4 view;
		/// Matriz de proyecci�n.
		alignas(16) glm::mat4 proj;
		/// Indica si el objeto est� seleccionado.
		bool selected = false;

		/**
			* @brief Actualiza la matriz de modelo y el estado de selecci�n a partir de un objeto f�sico.
			* 
			* La transformaci�n se calcula utilizando la posici�n y el radio del objeto.
			*
			* @param object Objeto f�sico del cual se extraen los datos.
			*/
		void updateModel(const Physic::PhysicObject& object,float deltaTime)
		{
			float angle = 360 * deltaTime / 1000;
			this->model = glm::translate(glm::mat4(1.0f), object._position * 0.00001f) *
				glm::rotate(glm::mat4(1.0f), glm::radians(angle), glm::vec3(0, 1, 0)) *
				glm::scale(glm::mat4(1.0f), glm::vec3(object._radius * 0.00001f,
					                                        object._radius * 0.00001f,
					                                        object._radius * 0.00001f));
			this->selected = object._selected;
		}
	};

	/**
		* @struct Vertex
		* @brief Representa la informaci�n de un v�rtice, incluyendo posici�n y color.
		*/
	struct Vertex {
		/// Posici�n del v�rtice.
		glm::vec3 pos;
		/// Color del v�rtice.
		glm::vec3 color;

		/**
			* @brief Constructor para inicializar un v�rtice.
			* @param pos Posici�n del v�rtice.
			* @param color Color del v�rtice.
			*/
		Vertex(glm::vec3 pos, glm::vec3 color) : pos(pos), color(color) {};

		/**
			* @brief Obtiene la descripci�n del binding de entrada de v�rtices.
			*
			* Esta descripci�n indica c�mo se deben interpretar los datos del v�rtice.
			*
			* @return VkVertexInputBindingDescription Descripci�n del binding.
			*/
		static VkVertexInputBindingDescription getBindingDescription() {
			VkVertexInputBindingDescription bindingDescription{};
			bindingDescription.binding = 0;
			bindingDescription.stride = sizeof(Vertex);
			bindingDescription.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
			return bindingDescription;
		}

		/**
			* @brief Obtiene las descripciones de los atributos de entrada del v�rtice.
			*
			* Se definen dos atributos:
			* - Posici�n: ubicaci�n 0, formato de tres componentes de 32 bits.
			* - Color: ubicaci�n 1, formato de tres componentes de 32 bits.
			*
			* @return std::array<VkVertexInputAttributeDescription, 2> Array con las descripciones de atributos.
			*/
		static std::array<VkVertexInputAttributeDescription, 2> getAttributeDescriptions() {
			std::array<VkVertexInputAttributeDescription, 2> attributeDescriptions{};
			attributeDescriptions[0].binding = 0;
			attributeDescriptions[0].location = 0;
			attributeDescriptions[0].format = VK_FORMAT_R32G32B32_SFLOAT;
			attributeDescriptions[0].offset = offsetof(Vertex, pos);

			attributeDescriptions[1].binding = 0;
			attributeDescriptions[1].location = 1;
			attributeDescriptions[1].format = VK_FORMAT_R32G32B32_SFLOAT;
			attributeDescriptions[1].offset = offsetof(Vertex, color);
			return attributeDescriptions;
		}
	};
}