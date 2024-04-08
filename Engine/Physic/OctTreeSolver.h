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

            OctTreeSolver(OctTree& tree, float accuracy) : tree(&tree), accuracy(accuracy) {}

            void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects);

        private:
            OctTree* tree;
            float accuracy;
        };
    }
}


