#pragma once
#include "CollisionDetectionInterface.h"
#include <memory>
#include <vector>
namespace Engine::Physic
{
	class bruteForceDetection : public CollisionDetectionInterface
	{
		void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


