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
		void update(double deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects, int numObjects);

		PhysicSystem(std::unique_ptr<Engine::Physic::BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm, std::unique_ptr<Engine::Physic::NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm, std::shared_ptr<std::vector<PhysicObject>> objects, int numObjects);
		PhysicSystem() = default;
	private:
		
		double systemEnergy = 0;
		double deltaEnergy = 0;
		void checkEnergyConservation(std::shared_ptr<std::vector<PhysicObject>> objects,int numObjects);

		std::unique_ptr<Engine::Physic::BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm;
		std::unique_ptr<Engine::Physic::NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm;
		std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm;
	};
}

