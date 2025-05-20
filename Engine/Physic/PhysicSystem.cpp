#include "PhysicSystem.h"
#include "chrono"
namespace Engine::Physic
{
	const float PhysicSystem::UNIVERSAL_GRAVITATION = 6.6743e-11f;
	void PhysicSystem::update(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects)
	{
		if (_collitionDetectionAlgorithm == nullptr && _solverAlgorithm == nullptr) return;
		_collitionDetectionAlgorithm->detection(deltaTime,objects);
		_solverAlgorithm->solve(deltaTime,objects);
	}

	PhysicSystem::PhysicSystem(std::unique_ptr<CollisionDetectionInterface> collitionDetectionAlgorithm,
		std::unique_ptr<SolverInterface> solverAlgorithm):
		_collitionDetectionAlgorithm(std::move(collitionDetectionAlgorithm)),
		_solverAlgorithm(std::move(solverAlgorithm))
	{
	}
}
