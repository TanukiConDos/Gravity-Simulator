#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	class NarrowCollisionDetectionInterface
	{
	public:
		virtual void narrowDetection(double deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects, int numObjects);
	};
}