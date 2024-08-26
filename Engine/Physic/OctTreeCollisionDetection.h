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

			explicit OctTreeCollisionDetection(std::shared_ptr<OctTree> tree): _tree(tree) {}

			void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
		private:
			std::shared_ptr<OctTree> _tree;

		};

	}
}

