#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	class NarrowCollisionDetectionInterface
	{
	public:
		virtual void narrowDetection(double deltaTime,std::vector<Engine::Physic::PhysicObject>& objects);
	};
}