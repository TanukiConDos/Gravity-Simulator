#pragma once
#include "CollisionDetectionInterface.h"
#include "SolverInterface.h"
#include <iostream>

namespace Engine::Physic
{
	class PhysicSystem
	{
	public:

		static const float UNIVERSAL_GRAVITATION;
		void update(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects);

		PhysicSystem(std::unique_ptr<CollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<SolverInterface> solverAlgorithm);
		PhysicSystem() = default;
	private:
		std::unique_ptr<CollisionDetectionInterface> collitionDetectionAlgorithm;
		std::unique_ptr<SolverInterface> solverAlgorithm;
	};
}

