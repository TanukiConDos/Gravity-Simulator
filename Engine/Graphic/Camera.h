/**
 * @file Camera.h
 * @brief Gestiona la cámara de la escena, proporcionando métodos para actualizar la vista y la proyección.
 */

#pragma once
#include "SwapChain.h"
#include <glm/glm.hpp>

namespace Engine::Graphic
{
	/**
		* @class Camera
		* @brief Clase que controla la posición, orientación y proyección de la cámara.
		*
		* La cámara se inicializa a partir de un SwapChain para obtener las dimensiones de la ventana, y proporciona métodos para
		* obtener vectores direccionales, transformar UniformBufferObjects, mover y rotar la cámara.
		*/
	class Camera
	{
	public:
		Camera(const Camera&) = delete;
		Camera& operator=(const Camera&) = delete;

		/**
			* @brief Constructor.
			* @param swapchain Referencia al SwapChain que se utiliza para configurar la proyección.
			*/
		explicit Camera(SwapChain& swapchain);

		/**
			* @brief Obtiene el vector de dirección de la cámara.
			* @return glm::vec3 Vector dirección.
			*/
		glm::vec3 getDir() const { return _dir; }

		/**
			* @brief Obtiene el vector "up" de la cámara.
			* @return glm::vec3 Vector hacia arriba.
			*/
		glm::vec3 getUp() const { return _up; }

		/**
			* @brief Obtiene el vector hacia la izquierda de la cámara.
			* @return glm::vec3 Vector izquierda.
			*/
		glm::vec3 getLeft() const { return _left; }

		/**
			* @brief Transforma un UniformBufferObject utilizando la matriz de vista y proyección de la cámara.
			* @param ubo Objeto de buffer uniforme a actualizar.
			*/
		void transform(UniformBufferObject& ubo) const;

		/**
			* @brief Desplaza la posición de la cámara.
			* @param translation Vector de translación que se suma a la posición actual.
			*/
		void move(glm::vec3 translation);

		/**
			* @brief Rota la cámara.
			* @param degrees Ángulo de rotación en grados.
			* @param vertical true para una rotación vertical; false para horizontal.
			*/
		void rotate(float degrees, bool vertical);
	private:
		/// Referencia al SwapChain, se usa para obtener las dimensiones de la ventana para la proyección.
		SwapChain& _swapchain;
		/// Posición de la cámara.
		glm::vec3 _pos = { 0.0f, 0.0f, 4500.0f };
		/// Vector de dirección hacia donde mira la cámara.
		glm::vec3 _dir = glm::normalize(glm::vec3{0.0f, 0.0f, -1.0f});
		/// Vector que apunta hacia la izquierda de la cámara.
		glm::vec3 _left = glm::normalize(glm::cross(glm::vec3{ 0.0f, 1.0f, 0.0f }, _dir));
		/// Vector que apunta hacia arriba en la orientación de la cámara.
		glm::vec3 _up = glm::cross(_dir, _left);
		/// Matriz de vista de la cámara.
		glm::mat4 _view;
		/// Matriz de proyección de la cámara.
		glm::mat4 _projection;
	};
}


