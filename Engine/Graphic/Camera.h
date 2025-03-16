/**
 * @file Camera.h
 * @brief Gestiona la c�mara de la escena, proporcionando m�todos para actualizar la vista y la proyecci�n.
 */

#pragma once
#include "SwapChain.h"
#include <glm/glm.hpp>

namespace Engine::Graphic
{
	/**
		* @class Camera
		* @brief Clase que controla la posici�n, orientaci�n y proyecci�n de la c�mara.
		*
		* La c�mara se inicializa a partir de un SwapChain para obtener las dimensiones de la ventana, y proporciona m�todos para
		* obtener vectores direccionales, transformar UniformBufferObjects, mover y rotar la c�mara.
		*/
	class Camera
	{
	public:
		Camera(const Camera&) = delete;
		Camera& operator=(const Camera&) = delete;

		/**
			* @brief Constructor.
			* @param swapchain Referencia al SwapChain que se utiliza para configurar la proyecci�n.
			*/
		explicit Camera(SwapChain& swapchain);

		/**
			* @brief Obtiene el vector de direcci�n de la c�mara.
			* @return glm::vec3 Vector direcci�n.
			*/
		glm::vec3 getDir() const { return _dir; }

		/**
			* @brief Obtiene el vector "up" de la c�mara.
			* @return glm::vec3 Vector hacia arriba.
			*/
		glm::vec3 getUp() const { return _up; }

		/**
			* @brief Obtiene el vector hacia la izquierda de la c�mara.
			* @return glm::vec3 Vector izquierda.
			*/
		glm::vec3 getLeft() const { return _left; }

		/**
			* @brief Transforma un UniformBufferObject utilizando la matriz de vista y proyecci�n de la c�mara.
			* @param ubo Objeto de buffer uniforme a actualizar.
			*/
		void transform(UniformBufferObject& ubo) const;

		/**
			* @brief Desplaza la posici�n de la c�mara.
			* @param translation Vector de translaci�n que se suma a la posici�n actual.
			*/
		void move(glm::vec3 translation);

		/**
			* @brief Rota la c�mara.
			* @param degrees �ngulo de rotaci�n en grados.
			* @param vertical true para una rotaci�n vertical; false para horizontal.
			*/
		void rotate(float degrees, bool vertical);
	private:
		/// Referencia al SwapChain, se usa para obtener las dimensiones de la ventana para la proyecci�n.
		SwapChain& _swapchain;
		/// Posici�n de la c�mara.
		glm::vec3 _pos = { 0.0f, 0.0f, 4500.0f };
		/// Vector de direcci�n hacia donde mira la c�mara.
		glm::vec3 _dir = glm::normalize(glm::vec3{0.0f, 0.0f, -1.0f});
		/// Vector que apunta hacia la izquierda de la c�mara.
		glm::vec3 _left = glm::normalize(glm::cross(glm::vec3{ 0.0f, 1.0f, 0.0f }, _dir));
		/// Vector que apunta hacia arriba en la orientaci�n de la c�mara.
		glm::vec3 _up = glm::cross(_dir, _left);
		/// Matriz de vista de la c�mara.
		glm::mat4 _view;
		/// Matriz de proyecci�n de la c�mara.
		glm::mat4 _projection;
	};
}


