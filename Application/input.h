/**
 * @file input.h
 * @brief Define acciones de entrada y eventos para la aplicaci�n.
 */

#pragma once
namespace Engine::Graphic
{
	/**
	 * @brief Declaraci�n adelantada de la clase Camera.
	 */
	class Camera;
}

namespace Application
{
	/**
	 * @enum InputAction
	 * @brief Enumera las acciones de entrada disponibles en la aplicaci�n.
	 *
	 * - MOVE_FORWARD: Moverse hacia adelante.
	 * - MOVE_BACKWARD: Moverse hacia atr�s.
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
	 * @brief Gestiona los eventos de entrada en la aplicaci�n.
	 *
	 * Permite suscribir una c�mara para recibir notificaciones de entrada y enviar acciones de entrada
	 * que pueden ser procesadas, por ejemplo, para mover o rotar la c�mara.
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
		 * @brief Asocia una c�mara para recibir eventos de entrada.
		 *
		 * @param camera Puntero a la c�mara que procesar� los eventos.
		 */
		void subscribe(Engine::Graphic::Camera* camera) { this->_camera = camera; }

		/**
		 * @brief Env�a una acci�n de entrada.
		 *
		 * Este m�todo procesa la acci�n de entrada indicada.
		 *
		 * @param action Acci�n de entrada a enviar.
		 */
		void submit(InputAction action);
	private:
		/// Puntero a la c�mara a la que se env�an los eventos.
		Engine::Graphic::Camera* _camera;
	};
}