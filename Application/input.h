#pragma once
namespace Engine::Graphic
{
	class Camera;
}


namespace Application
{

	enum InputAction
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

	class InputEvent
	{
	public:

		InputEvent(const InputEvent&) = delete;
		InputEvent& operator=(const InputEvent&) = delete;

		InputEvent() = default;

		void subscribe(Engine::Graphic::Camera* camera) { this->_camera = camera;}
		void submit(InputAction action);
	private:
		Engine::Graphic::Camera* _camera;
	};
}