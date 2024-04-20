#include "BruteForceSolver.h"



namespace Engine::Physic
{
	void BruteForceSolver::solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects)
	{
		for (int i = 0; i < objects->size(); i++)
		{
			PhysicObject* object = objects->at(i);
			glm::vec3 totalForce = glm::vec3{0,0,0};

			for (int j = 0; j < objects->size(); j++)
			{
				if (i != j)
				{
					PhysicObject* object2 = objects->at(j);
					double distance = glm::distance(object->position, object2->position);
					if (distance > object->radius + object2->radius + 1000)
					{
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->mass * object2->mass) / (distance * distance)) * (glm::dvec3) glm::normalize(object->position - object2->position));
					}
				}
			}
			object->update(deltaTime, totalForce);
		}
	}
}