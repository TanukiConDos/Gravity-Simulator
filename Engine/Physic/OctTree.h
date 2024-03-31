#pragma once
#include <vector>
#include <limits>
#include "PhysicObject.h"
#include <memory>
#include <stack>

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

				Node(glm::dvec3 start, glm::dvec3 end);
				Node() = default;
				//void addObject(PhysicObject& objects, std::stack<Node>& stack);

				
				int numChilds = 0;
				Node* childs[8];
				std::vector<PhysicObject*> objects = std::vector<PhysicObject*>();
				glm::dvec3 start;
				glm::dvec3 end;

				void checkObjects();
				
			};
			Node root = Node(glm::dvec3{ std::numeric_limits<double>::lowest() , std::numeric_limits<double>::lowest() , std::numeric_limits<double>::lowest() },
				glm::dvec3{ std::numeric_limits<double>::max(), std::numeric_limits<double>::max(), std::numeric_limits<double>::max() });
			void insert();
		};
	}
	

	
}

