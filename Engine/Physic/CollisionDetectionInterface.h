#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	class CollisionDetectionInterface
	{
	public:
		virtual void detection(double deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects);
	};
}