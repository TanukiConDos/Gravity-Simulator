#pragma once
#include "SolverInterface.h"
#include "OctTree.h"

namespace Engine
{
    namespace Physic
    {
        class OctTreeSolver: public SolverInterface
        {
        public:

            explicit OctTreeSolver(std::shared_ptr<OctTree> tree) : _tree(tree) {}

            void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;

        private:
            std::shared_ptr<OctTree> _tree;
        };
    }
}


