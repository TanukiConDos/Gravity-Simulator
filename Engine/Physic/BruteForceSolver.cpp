#include "BruteForceSolver.h"



namespace Engine::Physic
{
	void BruteForceSolver::solve(double deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects)
	{
		for (int i = 0; i < objects->size(); i++)
		{
			PhysicObject* object = objects->at(i);
			glm::dvec3 totalForce = glm::dvec3{0,0,0};

			for (int j = 0; j < objects->size(); j++)
			{
				if (i != j)
				{
					PhysicObject* object2 = objects->at(j);
					double distance = glm::distance(object->getPosition(), object2->getPosition());
					if (distance > object->getRadius() + object2->getRadius() + 1000)
					{
						totalForce = totalForce + ((-PhysicSystem::UNIVERSAL_GRAVITATION * object->getMass() * object2->getMass()) / (distance * distance)) * glm::normalize(object->getPosition() - object2->getPosition());
					}
				}
			}
			object->update(deltaTime, totalForce);
		}
	}
}