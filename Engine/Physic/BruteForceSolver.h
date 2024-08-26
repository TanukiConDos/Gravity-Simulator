#pragma once
#include "SolverInterface.h"
#include "PhysicSystem.h"
#include <iostream>
#include <vector>


namespace Engine::Physic
{
	class BruteForceSolver: public SolverInterface
	{
	public:
		void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


