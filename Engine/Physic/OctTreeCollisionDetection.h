#pragma once
#include "CollisionDetectionInterface.h"
#include "OctTree.h"

namespace Engine
{
	namespace Physic
	{
		class OctTreeCollisionDetection : public CollisionDetectionInterface
		{
		public:

			OctTreeCollisionDetection(OctTree& tree): tree(&tree) {}

			void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects);
		private:
			OctTree* tree;

		};

	}
}

