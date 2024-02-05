#include "PhysicSystem.h"

namespace Engine::Physic
{
	const double PhysicSystem::UNIVERSAL_GRAVITATION = 6.67430e-11;
	void PhysicSystem::update(double deltaTime,std::shared_ptr<std::vector<PhysicObject>> objects,int numObjects)
	{
		broadCollitionDetectionAlgorithm->broadDetection(objects,numObjects);
		narrowCollitionDetectionAlgorithm->narrowDetection(deltaTime,objects, numObjects);
		solverAlgorithm->solve(deltaTime,objects,numObjects);
		checkEnergyConservation(objects, numObjects);
	}

	PhysicSystem::PhysicSystem(std::unique_ptr<Engine::Physic::BroadCollisionDetectionInterface> broadCollitionDetectionAlgorithm, std::unique_ptr<Engine::Physic::NarrowCollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm, std::shared_ptr<std::vector<PhysicObject>> objects, int numObjects)
		
	{
		this->broadCollitionDetectionAlgorithm = std::move(broadCollitionDetectionAlgorithm);
		this->narrowCollitionDetectionAlgorithm = std::move(narrowCollitionDetectionAlgorithm);
		this->solverAlgorithm = std::move(solverAlgorithm);
		checkEnergyConservation(objects, numObjects);
	}
	void PhysicSystem::checkEnergyConservation(std::shared_ptr<std::vector<PhysicObject>> objects,int numObjects)
	{
		double totalEnergy = 0.0;
		for (int i = 0; i < numObjects; i++)
		{
			PhysicObject object = objects->at(i);
			double kinetic = 0.5 * object.getMass() * object.getVelocity() * object.getVelocity();
			double potential = 0;
			for (int j = 0; j < numObjects; j++)
			{
				if (i != j)
				{
					PhysicObject object2 = objects->at(j);
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
		std::cout << "delta: " << deltaEnergy << std::endl;
	}
}
