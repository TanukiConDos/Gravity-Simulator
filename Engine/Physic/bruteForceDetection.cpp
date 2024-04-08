#include "bruteForceDetection.h"
#include <chrono>
#include <iostream>
namespace Engine::Physic
{
	void bruteForceDetection::detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects)
	{
		for (int i = 0; i < objects->size(); i++)
		{
			PhysicObject* object = objects->at(i);
			for (int j = 0; j < objects->size(); j++)
			{
				if (i != j)
				{
					PhysicObject* object2 = objects->at(j);
					object->collision(*object2);
				}
			}
		}
	}
}