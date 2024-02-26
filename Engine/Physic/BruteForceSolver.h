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
		void solve(double deltaTime,std::vector<PhysicObject>& objects);
	};
}


