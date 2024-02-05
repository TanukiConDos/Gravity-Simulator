#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	class SolverInterface
	{
	public:
		virtual void solve(double deltaTime,std::shared_ptr<std::vector<PhysicObject>> objects,int numObjects);
	};
}
