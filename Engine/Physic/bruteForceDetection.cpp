#include "bruteForceDetection.h"

namespace Engine::Physic
{
	void bruteForceDetection::narrowDetection(double deltaTime, std::vector<PhysicObject>& objects)
	{
		for (int i = 0; i < objects.size(); i++)
		{
			PhysicObject& object = objects[i];
			for (int j = 0; j < objects.size(); j++)
			{
				if (i != j)
				{
					PhysicObject& object2 = objects[j];
					object.collision(object2);

				}
			}
		}
	}
}