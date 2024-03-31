#include "OctTreeCollisionDetection.h"

void Engine::Physic::OctTreeCollisionDetection::detection(double deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects)
{
	tree->update();
	tree->checkCollisions();
}
