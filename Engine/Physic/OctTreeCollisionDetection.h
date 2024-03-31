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

			OctTreeCollisionDetection(std::shared_ptr<std::vector<PhysicObject*>> objects) { tree = std::make_unique<Engine::Physic::OctTree>(objects); }

			void detection(double deltaTime, std::shared_ptr<std::vector<PhysicObject*>> objects);
		private:
			std::unique_ptr<OctTree> tree;

		};

	}
}

