#pragma once
#include "NarrowCollisionDetectionInterface.h"
#include <memory>
#include <vector>
namespace Engine::Physic
{
	class bruteForceDetection : public NarrowCollisionDetectionInterface
	{
		void narrowDetection(double deltaTime,std::vector<PhysicObject>& objects);
	};
}


