#pragma once
#include "CollisionDetectionInterface.h"
#include "SolverInterface.h"
#include <iostream>

namespace Engine::Physic
{
	class PhysicSystem
	{
	public:

		static const double UNIVERSAL_GRAVITATION;
		void update(double deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects);

		PhysicSystem(std::unique_ptr<CollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<SolverInterface> solverAlgorithm);
		PhysicSystem() = default;
	private:
		
		double systemEnergy = 0;
		double deltaEnergy = 0;
		void checkEnergyConservation(std::shared_ptr<std::vector<PhysicObject*>> objects);

		std::unique_ptr<CollisionDetectionInterface> collitionDetectionAlgorithm;
		std::unique_ptr<SolverInterface> solverAlgorithm;
	};
}

