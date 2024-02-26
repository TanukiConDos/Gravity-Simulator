#pragma once
#include "NarrowCollisionDetectionInterface.h"
#include "BroadCollisionDetectionInterface.h"
#include "SolverInterface.h"
#include <iostream>

namespace Engine::Physic
{
	class PhysicSystem
	{
	public:

		static const double UNIVERSAL_GRAVITATION;
		void update(double deltaTime, std::vector<Engine::Physic::PhysicObject>& objects);

		PhysicSystem(std::unique_ptr<BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm, std::unique_ptr<NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<SolverInterface> solverAlgorithm);
		PhysicSystem() = default;
	private:
		
		double systemEnergy = 0;
		double deltaEnergy = 0;
		void checkEnergyConservation(std::vector<Engine::Physic::PhysicObject>& objects);

		std::unique_ptr<BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm;
		std::unique_ptr<NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm;
		std::unique_ptr<SolverInterface> solverAlgorithm;
	};
}

