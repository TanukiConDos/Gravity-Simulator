#include "OctTreeSolver.h"

void Engine::Physic::OctTreeSolver::solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects)
{
	_tree->update(deltaTime);
	for (int objectId = 0; objectId < objects->size(); objectId++)
	{
		glm::vec3 force = _tree->barnesHut(objectId, deltaTime);
		objects->at(objectId).update(deltaTime,force);
	}
}
