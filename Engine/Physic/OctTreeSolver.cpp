#include "OctTreeSolver.h"

void Engine::Physic::OctTreeSolver::solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects)
{
	tree->update();
	tree->barnesHut(deltaTime);
}
