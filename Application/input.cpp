#include "input.h"
#include "../Engine/Graphic/Camera.h"
#include <glm/glm.hpp>

void Application::InputEvent::submit(InputAction action)
{
	switch (action)
	{
	case InputAction::MOVE_FORWARD:
		camera->move(20.0f * camera->getDir());
		break;

	case InputAction::MOVE_BACKWARD:
		camera->move(-20.0f * camera->getDir());
		break;

	case InputAction::MOVE_LEFT_SIDE:
		camera->move(20.0f * camera->getLeft());
		break;

	case InputAction::MOVE_RIGHT_SIDE:
		camera->move(-20.0f * camera->getLeft());
		break;

	case InputAction::MOVE_UP:
		camera->move(20.0f * camera->getUp());
		break;
	case InputAction::MOVE_DOWN:
		camera->move(-20.0f * camera->getUp());
		break;
	case InputAction::ROTATE_UP:
		camera->rotate(1, true);
		break;
	case InputAction::ROTATE_DOWN:
		camera->rotate(-1, true);
		break;
	case InputAction::ROTATE_LEFT:
		camera->rotate(1, false);
		break;
	case InputAction::ROTATE_RIGHT:
		camera->rotate(-1, false);
		break;
	}
}
