#include "input.h"
#include "../Engine/Graphic/Camera.h"
#include "../../External/glm/glm.hpp"

void Application::InputEvent::submit(InputAction action)
{
	switch (action)
	{
	case InputAction::MOVE_FORWARD:
		_camera->move(20.0f * _camera->getDir());
		break;

	case InputAction::MOVE_BACKWARD:
		_camera->move(-20.0f * _camera->getDir());
		break;

	case InputAction::MOVE_LEFT_SIDE:
		_camera->move(20.0f * _camera->getLeft());
		break;

	case InputAction::MOVE_RIGHT_SIDE:
		_camera->move(-20.0f * _camera->getLeft());
		break;

	case InputAction::MOVE_UP:
		_camera->move(20.0f * _camera->getUp());
		break;
	case InputAction::MOVE_DOWN:
		_camera->move(-20.0f * _camera->getUp());
		break;
	case InputAction::ROTATE_UP:
		_camera->rotate(1, true);
		break;
	case InputAction::ROTATE_DOWN:
		_camera->rotate(-1, true);
		break;
	case InputAction::ROTATE_LEFT:
		_camera->rotate(1, false);
		break;
	case InputAction::ROTATE_RIGHT:
		_camera->rotate(-1, false);
		break;
	}
}
