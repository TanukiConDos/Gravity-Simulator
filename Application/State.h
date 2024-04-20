#pragma once

#include<string>
#include<functional>
#include "../External/imgui/imgui.h"

namespace Engine::Graphic
{
	class ImGUIWindow;
}

namespace Application
{
	class GravitySimulator;

	enum Action
	{
		DEFAULT,
		BEGIN_SIMULATION,
		CONFIGURATION,
		SAVE,

	};

	class State;


	class StateMachine
	{
	public:
		StateMachine(StateMachine const&) = delete;
		StateMachine operator=(StateMachine const&) = delete;
		static StateMachine* getStateMachine();
		void frame();
		void changeState(State* state) { this->state = state; }
		void subscribe(GravitySimulator* sub) { this->sub = sub; }
		GravitySimulator* getSub() { return sub; }
	private:
		State* state;
		GravitySimulator* sub;
		StateMachine() = default;

	};

	class State
	{
	public:
		State(StateMachine* context) : context(context) {}
		virtual void frame() {}
		virtual void changeState(Action action) {}
	protected:
		StateMachine* context;
	};

	class MainMenu: public State
	{
	public:
		MainMenu(StateMachine* context) : State(context) {}
		void frame();
		void changeState(Action action);
	};

	class Debug : public State
	{
	public:
		Debug(StateMachine* context, State* state) : State(context), state(state) {}
		void frame();
		void changeState(Action action);


	private:
		State* state;
	};

	class Config : public State
	{
	public:
		Config(StateMachine* context) : State(context) {}
		void frame();
		void changeState(Action action);
	};

	class ObjectSelected : public State
	{
	public:
		ObjectSelected(StateMachine* context, State* state) : State(context), state(state) { }
		void frame();
		void changeState(Action action);


	private:
		State* state;
	};
}