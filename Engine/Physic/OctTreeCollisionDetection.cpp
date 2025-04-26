#include "OctTreeCollisionDetection.h"

void Engine::Physic::OctTreeCollisionDetection::detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects)
{
	_tree->update(deltaTime);
	for (int objectId = 0; objectId < objects->size(); objectId++)
	{
		
		std::vector<int> potentialCollision = _tree->checkCollisions(objectId);
		PhysicObject* object = &objects->at(objectId);
		for (int id : potentialCollision)
		{
			if (objectId == id) continue;
			object->collision(objects->at(id));
		}
	}
}
