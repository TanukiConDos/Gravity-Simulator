#pragma once
#include <vector>
#include <limits>
#include "PhysicObject.h"
#include <memory>
#include <stack>

#include "PhysicSystem.h"
#include "../../Foundation/Arena.h"

namespace Engine
{
	namespace Physic
	{
		class OctTree
		{
		private:
			struct Node;
		public:
			OctTree(const OctTree&) = delete;
			OctTree& operator=(const OctTree&) = delete;

			OctTree(std::shared_ptr<std::vector<PhysicObject*>> objects);
			OctTree() = default;

			void barnesHut(float deltaTime);
			void massCalculation();
			void checkCollisions();
			void update();
		private:
			std::shared_ptr<std::vector<PhysicObject*>> objects;
			int ticks = 0;

			struct ObjectStruct {
			public:
				ObjectStruct* next = nullptr;
				PhysicObject* _object = nullptr;

				void append(PhysicObject* object, Foundation::Arena<ObjectStruct>& arena)
				{
					if (_object == nullptr)
					{
						_object = object;
						return;
					}
					if (next == nullptr) {
						next = arena.alloc(1);
						*next = ObjectStruct();
					}
					next->append(object,arena);
				}

				void get(std::vector<PhysicObject*>& objects)
				{
					if (next != nullptr)
					{
						next->get(objects);
					}
					objects.emplace_back(_object);
				}
			};

			struct Node
			{
			public:
				Node(glm::vec3 start, glm::vec3 end);

				float width;
				double mass = 0;
				bool noChilds = true;
				Node* childs = nullptr;
				ObjectStruct* objects = nullptr;
				int depth = -1;
				glm::vec3 start;
				glm::vec3 end;
				glm::vec3 center;
			};
			Node* root;
			Foundation::Arena<Node> arenaNode = Foundation::Arena<Node>(40000);
			Foundation::Arena<ObjectStruct> arenaObject = Foundation::Arena<ObjectStruct>(2000000);
			void insert();
			bool expand(Node* node,int depth);
		};
	}
	

	
}

