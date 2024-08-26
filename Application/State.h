#pragma once

#include<string>
#include<functional>
#include "../External/imgui/imgui.h"
#include "../Engine/Physic/PhysicObject.h"

namespace Engine::Graphic
{
	class ImGUIWindow;
}

namespace Application
{
	class State;
	class StateMachine;

	static std::shared_ptr<StateMachine> g_stateMachine;

	class GravitySimulator;

	enum class Action
	{
		DEFAULT,
		BEGIN_SIMULATION,
		CONFIGURATION,
		SAVE,
		EXIT

	};




	class StateMachine
	{
	public:
		std::unique_ptr<State> _state;
		std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _objects;
		GravitySimulator* _sub;
		float* _frameTime;
		float* _tickTime;

		StateMachine(StateMachine const&) = delete;
		StateMachine operator=(StateMachine const&) = delete;

		StateMachine() = default;
		static std::shared_ptr<StateMachine> getStateMachine();
		void frame();
		void changeState(std::unique_ptr<State> state) { _state = std::move(state); }

	};

	class State
	{
	public:
		explicit State(std::shared_ptr<StateMachine> context) : _context(context) {}
		virtual void frame() {}
		virtual void changeState(Action action) {}
	protected:
		std::shared_ptr<StateMachine> _context;
	};

	class MainMenu: public State
	{
	public:
		explicit MainMenu(std::shared_ptr<StateMachine> context) : State(context) {}
		void frame() final;
		void changeState(Action action) final;
	};

	class Debug : public State
	{
	public:
		Debug(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state) : State(context), _state(std::move(state)) {}
		void frame() final;
		void changeState(Action action) final;


	private:
		std::unique_ptr<State> _state;
	};

	class Config : public State
	{
	public:
		explicit Config(std::shared_ptr<StateMachine> context) : State(context) {}
		void frame() final;
		void changeState(Action action) final;
	};

	class ObjectSelected : public State
	{
	public:
		ObjectSelected(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state);
		void frame() final;
		void changeState(Action action) final;


	private:
		std::unique_ptr<State> _state;
		int _objectId = 0;
		int _oldId = -1;
		std::array<float*,3> _pos;
		std::array<float*, 3> _vel;
		std::array<float*, 3> _acc;
		double* _mass;
		float* _radius;
	};
}