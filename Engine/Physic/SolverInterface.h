#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	class SolverInterface
	{
	public:
		virtual void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects);
	};
}
