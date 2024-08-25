#include "PhysicSystem.h"
#include "chrono"
namespace Engine::Physic
{
	const float PhysicSystem::UNIVERSAL_GRAVITATION = 6.6743e-11f;
	void PhysicSystem::update(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects)
	{
		if (collitionDetectionAlgorithm == nullptr && solverAlgorithm == nullptr) return;
		collitionDetectionAlgorithm->detection(deltaTime,objects);
		solverAlgorithm->solve(deltaTime,objects);
		//checkEnergyConservation(objects);
	}

	PhysicSystem::PhysicSystem(std::unique_ptr<CollisionDetectionInterface> collitionDetectionAlgorithm,
		std::unique_ptr<SolverInterface> solverAlgorithm):
		collitionDetectionAlgorithm(std::move(collitionDetectionAlgorithm)),
		solverAlgorithm(std::move(solverAlgorithm))
	{
	}
}
