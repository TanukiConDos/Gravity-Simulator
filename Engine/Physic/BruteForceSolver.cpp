#include "BruteForceSolver.h"



namespace Engine::Physic
{
	void BruteForceSolver::solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects)
	{
		for (int i = 0; i < objects->size(); i++)
		{
			PhysicObject* object = &objects->at(i);
			glm::vec3 totalForce = glm::vec3{0,0,0};

			for (int j = 0; j < objects->size(); j++)
			{
				if (i != j)
				{
					PhysicObject* object2 = &objects->at(j);
					double distance = glm::distance(object->_position, object2->_position);
					if (distance > object->_radius + object2->_radius + 1000)
					{
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->_mass * object2->_mass) / (distance * distance)) * (glm::dvec3) glm::normalize(object->_position - object2->_position));
					}
				}
			}
			object->update(deltaTime, totalForce);
		}
	}
}