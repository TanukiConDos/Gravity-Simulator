/**
 * @file State.h
 * @brief Define los estados y la máquina de estados para la aplicación.
 */

#pragma once

#include<string>
#include<functional>
#include "../External/imgui/imgui.h"
#include "../Engine/Physic/PhysicObject.h"

/**
 * @namespace Application
 * @brief Namespace que contiene clases, enumeradores y funciones para el manejo de estados de la aplicación.
 */
namespace Engine::Graphic
{
	class ImGUIWindow;
}

namespace Application
{
	/**
	 * @brief Declaración adelantada de la clase State.
	 */
	class State;
	/**
	 * @brief Declaración adelantada de la clase StateMachine.
	 */
	class StateMachine;

	/** @brief Instancia global de la máquina de estados. */
	static std::shared_ptr<StateMachine> g_stateMachine;

	/**
	 * @brief Declaración adelantada de GravitySimulator, encargado de la simulación de gravedad.
	 */
	class GravitySimulator;

	/**
	 * @enum Action
	 * @brief Enumera las acciones disponibles para cambiar el estado de la aplicación.
	 */
	enum class Action
	{
		DEFAULT,          ///< Acción por defecto.
		BEGIN_SIMULATION, ///< Inicia la simulación.
		CONFIGURATION,    ///< Entra al modo de configuración.
		SAVE,             ///< Guarda el estado o configuración.
		EXIT              ///< Sale de la aplicación.
	};

	/**
	 * @class StateMachine
	 * @brief Gestiona la transición y ejecución de estados en la aplicación.
	 */
	class StateMachine
	{
	public:
		/** @brief Estado actual de la máquina de estados. */
		std::unique_ptr<State> _state;
		/** @brief Colección de objetos físicos de la simulación. */
		std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _objects;
		/** @brief Puntero al sub-sistema GravitySimulator. */
		GravitySimulator* _sub;
		/** @brief Puntero al tiempo de frame. */
		float* _frameTime;
		/** @brief Puntero al tiempo de tick del sistema. */
		float* _tickTime;

		StateMachine(StateMachine const&) = delete;
		StateMachine operator=(StateMachine const&) = delete;

		StateMachine() = default;

		/**
		 * @brief Obtiene la instancia singleton de la máquina de estados.
		 * @return std::shared_ptr<StateMachine> Instancia de la máquina de estados.
		 */
		static std::shared_ptr<StateMachine> getStateMachine();

		/**
		 * @brief Ejecuta la lógica de cada frame utilizando el estado actual.
		 */
		void frame();

		/**
		 * @brief Cambia el estado actual de la máquina.
		 * @param state Nuevo estado que se adoptará.
		 */
		void changeState(std::unique_ptr<State> state) { _state = std::move(state); }
	};

	/**
	 * @class State
	 * @brief Clase base para los diferentes estados de la aplicación.
	 */
	class State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado con el contexto de la máquina de estados.
		 * @param context Puntero compartido al objeto StateMachine.
		 */
		explicit State(std::shared_ptr<StateMachine> context) : _context(context) {}

		/**
		 * @brief Ejecuta la lógica que debe ocurrir en cada frame.
		 */
		virtual void frame() {}

		/**
		 * @brief Gestiona la transición a otro estado basado en la acción.
		 * @param action Acción que determina el cambio de estado.
		 */
		virtual void changeState(Action action) {}

	protected:
		/** @brief Contexto (máquina de estados) de este estado. */
		std::shared_ptr<StateMachine> _context;
	};

	/**
	 * @class MainMenu
	 * @brief Estado que representa el menú principal de la aplicación.
	 */
	class MainMenu: public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el menú principal.
		 * @param context Puntero compartido a la máquina de estados.
		 */
		explicit MainMenu(std::shared_ptr<StateMachine> context) : State(context) {}

		/**
		 * @brief Ejecuta la lógica del frame para el menú principal.
		 */
		void frame() final;

		/**
		 * @brief Realiza la transición de estado basada en la acción seleccionada en el menú principal.
		 * @param action Acción de cambio de estado.
		 */
		void changeState(Action action) final;
	};

	/**
	 * @class Debug
	 * @brief Estado utilizado para depurar la aplicación.
	 */
	class Debug : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de depuración.
		 * @param context Puntero compartido a la máquina de estados.
		 * @param state Estado anidado para la depuración.
		 */
		Debug(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state) : State(context), _state(std::move(state)) {}

		/**
		 * @brief Ejecuta la lógica del frame en modo depuración.
		 */
		void frame() final;

		/**
		 * @brief Gestiona la transición a otro estado en modo depuración.
		 * @param action Acción que determina el cambio de estado.
		 */
		void changeState(Action action) final;

	private:
		/** @brief Estado anidado usado para operaciones de depuración. */
		std::unique_ptr<State> _state;
	};

	/**
	 * @class Config
	 * @brief Estado que maneja la configuración de la aplicación.
	 */
	class Config : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de configuración.
		 * @param context Puntero compartido a la máquina de estados.
		 */
		explicit Config(std::shared_ptr<StateMachine> context) : State(context) {}

		/**
		 * @brief Ejecuta la lógica del frame para la configuración.
		 */
		void frame() final;

		/**
		 * @brief Realiza la transición de estado basada en la acción en configuración.
		 * @param action Acción de cambio de estado.
		 */
		void changeState(Action action) final;
	};

	/**
	 * @class ObjectSelected
	 * @brief Estado que indica que se ha seleccionado un objeto en la simulación.
	 */
	class ObjectSelected : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de objeto seleccionado.
		 * @param context Puntero compartido a la máquina de estados.
		 * @param state Estado anidado.
		 */
		ObjectSelected(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state);

		/**
		 * @brief Ejecuta la lógica del frame cuando se ha seleccionado un objeto.
		 */
		void frame() final;

		/**
		 * @brief Gestiona la transición de estado basada en la acción cuando se ha seleccionado un objeto.
		 * @param action Acción de cambio de estado.
		 */
		void changeState(Action action) final;

	private:
		/** @brief Estado anidado utilizado durante la selección de un objeto. */
		std::unique_ptr<State> _state;
		/** @brief Identificador del objeto seleccionado. */
		int _objectId = 0;
		/** @brief Identificador previo del objeto seleccionado. */
		int _oldId = -1;
		/** @brief Posición del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*,3> _pos;
		/** @brief Velocidad del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*, 3> _vel;
		/** @brief Aceleración del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*, 3> _acc;
		/** @brief Puntero a la masa del objeto. */
		double* _mass;
		/** @brief Puntero al radio del objeto. */
		float* _radius;
	};
} // namespace Application