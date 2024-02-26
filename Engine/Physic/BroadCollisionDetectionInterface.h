#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>
#include <iostream>

namespace Engine::Physic
{
	class BroadCollisionDetectionInterface
	{
	public:
		virtual void broadDetection(std::vector<Engine::Physic::PhysicObject>& objects);

	};
}

