#include "PhysicSystem.h"

namespace Engine::Physic
{
	const double PhysicSystem::UNIVERSAL_GRAVITATION = 6.67430e-11;
	void PhysicSystem::update(double deltaTime, std::vector<Engine::Physic::PhysicObject>& objects)
	{
		broadCollitionDetectionAlgorithm->broadDetection(objects);
		narrowCollitionDetectionAlgorithm->narrowDetection(deltaTime,objects);
		solverAlgorithm->solve(deltaTime,objects);
		checkEnergyConservation(objects);
	}

	PhysicSystem::PhysicSystem(std::unique_ptr<BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm,
		std::unique_ptr<NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm,
		std::unique_ptr<SolverInterface> solverAlgorithm):
		broadCollitionDetectionAlgorithm(std::move(broadCollitionDetectionAlgorithm)),
		narrowCollitionDetectionAlgorithm(std::move(narrowCollitionDetectionAlgorithm)),
		solverAlgorithm(std::move(solverAlgorithm))
	{
	}

	void PhysicSystem::checkEnergyConservation(std::vector<Engine::Physic::PhysicObject>& objects)
	{
		double totalEnergy = 0.0;
		for (int i = 0; i < objects.size(); i++)
		{
			PhysicObject object = objects[i];
			double kinetic = 0.5 * object.getMass() * object.getVelocity() * object.getVelocity();
			double potential = 0;
			for (int j = 0; j < objects.size(); j++)
			{
				if (i != j)
				{
					PhysicObject object2 = objects[j];
					if (object.getMass() < object2.getMass())
					{
						double auxMass = UNIVERSAL_GRAVITATION * object.getMass() * object2.getMass();
						potential -= auxMass / glm::distance(object.getPosition(), object2.getPosition()) - auxMass / object.getRadius();
					}
					
				}
			}
			totalEnergy += potential + kinetic;
		}

		deltaEnergy = glm::abs(systemEnergy - totalEnergy);
		systemEnergy = totalEnergy;
	}
}
