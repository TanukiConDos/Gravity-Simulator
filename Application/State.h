/**
 * @file State.h
 * @brief Define los estados y la m�quina de estados para la aplicaci�n.
 */

#pragma once

#include<string>
#include<functional>
#include "../External/imgui/imgui.h"
#include "../Engine/Physic/PhysicObject.h"

/**
 * @namespace Application
 * @brief Namespace que contiene clases, enumeradores y funciones para el manejo de estados de la aplicaci�n.
 */
namespace Engine::Graphic
{
	class ImGUIWindow;
}

namespace Application
{
	/**
	 * @brief Declaraci�n adelantada de la clase State.
	 */
	class State;
	/**
	 * @brief Declaraci�n adelantada de la clase StateMachine.
	 */
	class StateMachine;

	/** @brief Instancia global de la m�quina de estados. */
	static std::shared_ptr<StateMachine> g_stateMachine;

	/**
	 * @brief Declaraci�n adelantada de GravitySimulator, encargado de la simulaci�n de gravedad.
	 */
	class GravitySimulator;

	/**
	 * @enum Action
	 * @brief Enumera las acciones disponibles para cambiar el estado de la aplicaci�n.
	 */
	enum class Action
	{
		DEFAULT,          ///< Acci�n por defecto.
		BEGIN_SIMULATION, ///< Inicia la simulaci�n.
		CONFIGURATION,    ///< Entra al modo de configuraci�n.
		SAVE,             ///< Guarda el estado o configuraci�n.
		EXIT              ///< Sale de la aplicaci�n.
	};

	/**
	 * @class StateMachine
	 * @brief Gestiona la transici�n y ejecuci�n de estados en la aplicaci�n.
	 */
	class StateMachine
	{
	public:
		/** @brief Estado actual de la m�quina de estados. */
		std::unique_ptr<State> _state;
		/** @brief Colecci�n de objetos f�sicos de la simulaci�n. */
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
		 * @brief Obtiene la instancia singleton de la m�quina de estados.
		 * @return std::shared_ptr<StateMachine> Instancia de la m�quina de estados.
		 */
		static std::shared_ptr<StateMachine> getStateMachine();

		/**
		 * @brief Ejecuta la l�gica de cada frame utilizando el estado actual.
		 */
		void frame();

		/**
		 * @brief Cambia el estado actual de la m�quina.
		 * @param state Nuevo estado que se adoptar�.
		 */
		void changeState(std::unique_ptr<State> state) { _state = std::move(state); }
	};

	/**
	 * @class State
	 * @brief Clase base para los diferentes estados de la aplicaci�n.
	 */
	class State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado con el contexto de la m�quina de estados.
		 * @param context Puntero compartido al objeto StateMachine.
		 */
		explicit State(std::shared_ptr<StateMachine> context) : _context(context) {}

		/**
		 * @brief Ejecuta la l�gica que debe ocurrir en cada frame.
		 */
		virtual void frame() {}

		/**
		 * @brief Gestiona la transici�n a otro estado basado en la acci�n.
		 * @param action Acci�n que determina el cambio de estado.
		 */
		virtual void changeState(Action action) {}

	protected:
		/** @brief Contexto (m�quina de estados) de este estado. */
		std::shared_ptr<StateMachine> _context;
	};

	/**
	 * @class MainMenu
	 * @brief Estado que representa el men� principal de la aplicaci�n.
	 */
	class MainMenu: public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el men� principal.
		 * @param context Puntero compartido a la m�quina de estados.
		 */
		explicit MainMenu(std::shared_ptr<StateMachine> context) : State(context) {}

		/**
		 * @brief Ejecuta la l�gica del frame para el men� principal.
		 */
		void frame() final;

		/**
		 * @brief Realiza la transici�n de estado basada en la acci�n seleccionada en el men� principal.
		 * @param action Acci�n de cambio de estado.
		 */
		void changeState(Action action) final;
	};

	/**
	 * @class Debug
	 * @brief Estado utilizado para depurar la aplicaci�n.
	 */
	class Debug : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de depuraci�n.
		 * @param context Puntero compartido a la m�quina de estados.
		 * @param state Estado anidado para la depuraci�n.
		 */
		Debug(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state) : State(context), _state(std::move(state)) {}

		/**
		 * @brief Ejecuta la l�gica del frame en modo depuraci�n.
		 */
		void frame() final;

		/**
		 * @brief Gestiona la transici�n a otro estado en modo depuraci�n.
		 * @param action Acci�n que determina el cambio de estado.
		 */
		void changeState(Action action) final;

	private:
		/** @brief Estado anidado usado para operaciones de depuraci�n. */
		std::unique_ptr<State> _state;
	};

	/**
	 * @class Config
	 * @brief Estado que maneja la configuraci�n de la aplicaci�n.
	 */
	class Config : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de configuraci�n.
		 * @param context Puntero compartido a la m�quina de estados.
		 */
		explicit Config(std::shared_ptr<StateMachine> context) : State(context) {}

		/**
		 * @brief Ejecuta la l�gica del frame para la configuraci�n.
		 */
		void frame() final;

		/**
		 * @brief Realiza la transici�n de estado basada en la acci�n en configuraci�n.
		 * @param action Acci�n de cambio de estado.
		 */
		void changeState(Action action) final;
	};

	/**
	 * @class ObjectSelected
	 * @brief Estado que indica que se ha seleccionado un objeto en la simulaci�n.
	 */
	class ObjectSelected : public State
	{
	public:
		/**
		 * @brief Constructor que inicializa el estado de objeto seleccionado.
		 * @param context Puntero compartido a la m�quina de estados.
		 * @param state Estado anidado.
		 */
		ObjectSelected(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state);

		/**
		 * @brief Ejecuta la l�gica del frame cuando se ha seleccionado un objeto.
		 */
		void frame() final;

		/**
		 * @brief Gestiona la transici�n de estado basada en la acci�n cuando se ha seleccionado un objeto.
		 * @param action Acci�n de cambio de estado.
		 */
		void changeState(Action action) final;

	private:
		/** @brief Estado anidado utilizado durante la selecci�n de un objeto. */
		std::unique_ptr<State> _state;
		/** @brief Identificador del objeto seleccionado. */
		int _objectId = 0;
		/** @brief Identificador previo del objeto seleccionado. */
		int _oldId = -1;
		/** @brief Posici�n del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*,3> _pos;
		/** @brief Velocidad del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*, 3> _vel;
		/** @brief Aceleraci�n del objeto (punteros a coordenadas X, Y, Z). */
		std::array<float*, 3> _acc;
		/** @brief Puntero a la masa del objeto. */
		double* _mass;
		/** @brief Puntero al radio del objeto. */
		float* _radius;
	};
} // namespace Application