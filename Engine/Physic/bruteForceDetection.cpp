#include "bruteForceDetection.h"

namespace Engine::Physic
{
	void bruteForceDetection::narrowDetection(double deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects, int numObjects)
	{
		for (int i = 0; i < numObjects; i++)
		{
			PhysicObject object = objects->at(i);
			for (int j = 0; j < numObjects; j++)
			{
				if (i != j)
				{
					PhysicObject object2 = objects->at(j);
					object.collision(object2);

				}
			}
		}
	}
}