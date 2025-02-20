/**
 * @file input.h
 * @brief Define acciones de entrada y eventos para la aplicación.
 */

#pragma once
namespace Engine::Graphic
{
	/**
	 * @brief Declaración adelantada de la clase Camera.
	 */
	class Camera;
}

namespace Application
{
	/**
	 * @enum InputAction
	 * @brief Enumera las acciones de entrada disponibles en la aplicación.
	 *
	 * - MOVE_FORWARD: Moverse hacia adelante.
	 * - MOVE_BACKWARD: Moverse hacia atrás.
	 * - MOVE_RIGHT_SIDE: Moverse hacia la derecha.
	 * - MOVE_LEFT_SIDE: Moverse hacia la izquierda.
	 * - MOVE_UP: Moverse hacia arriba.
	 * - MOVE_DOWN: Moverse hacia abajo.
	 * - ROTATE_UP: Rotar hacia arriba.
	 * - ROTATE_DOWN: Rotar hacia abajo.
	 * - ROTATE_LEFT: Rotar hacia la izquierda.
	 * - ROTATE_RIGHT: Rotar hacia la derecha.
	 */
	enum class InputAction
	{
		MOVE_FORWARD,
		MOVE_BACKWARD,
		MOVE_RIGHT_SIDE,
		MOVE_LEFT_SIDE,
		MOVE_UP,
		MOVE_DOWN,
		ROTATE_UP,
		ROTATE_DOWN,
		ROTATE_LEFT,
		ROTATE_RIGHT
	};

	/**
	 * @class InputEvent
	 * @brief Gestiona los eventos de entrada en la aplicación.
	 *
	 * Permite suscribir una cámara para recibir notificaciones de entrada y enviar acciones de entrada
	 * que pueden ser procesadas, por ejemplo, para mover o rotar la cámara.
	 */
	class InputEvent
	{
	public:
		InputEvent(const InputEvent&) = delete;
		InputEvent& operator=(const InputEvent&) = delete;

		/**
		 * @brief Constructor por defecto.
		 */
		InputEvent() = default;

		/**
		 * @brief Asocia una cámara para recibir eventos de entrada.
		 *
		 * @param camera Puntero a la cámara que procesará los eventos.
		 */
		void subscribe(Engine::Graphic::Camera* camera) { this->_camera = camera; }

		/**
		 * @brief Envía una acción de entrada.
		 *
		 * Este método procesa la acción de entrada indicada.
		 *
		 * @param action Acción de entrada a enviar.
		 */
		void submit(InputAction action);
	private:
		/// Puntero a la cámara a la que se envían los eventos.
		Engine::Graphic::Camera* _camera;
	};
}