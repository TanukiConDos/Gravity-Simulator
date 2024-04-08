#pragma once
#include <vector>
#include <limits>
#include "PhysicObject.h"
#include <memory>
#include <stack>

#include "PhysicSystem.h"

namespace Engine
{
	namespace Physic
	{
		class OctTree
		{
		public:
			
			OctTree(const OctTree&) = delete;
			OctTree& operator=(const OctTree&) = delete;

			OctTree(std::shared_ptr<std::vector<PhysicObject*>> objects);
			OctTree() = default;

			void barnesHut(double deltaTime);
			void massCalculation();
			void checkCollisions();
			void update();
		private:
			std::shared_ptr<std::vector<PhysicObject*>> objects;
			int ticks = 0;
			class Node
			{
			public:
				Node(const Node&) = delete;
				Node& operator= (const Node&) = delete;

				Node(glm::vec3 start, glm::vec3 end);
				Node() = default;

				float width;
				double mass = 0;
				bool noChilds = true;
				Node* childs[8];
				PhysicObject* object;
				glm::vec3 start;
				glm::vec3 end;
				glm::vec3 center;
				

				void expand();
			};
			Node* root = new Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 },
				glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
			void insert();
		};
	}
	

	
}

