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

			explicit OctTree(std::shared_ptr<std::vector<PhysicObject>> objects);
			OctTree() = default;

			void barnesHut(float deltaTime);
			void massCalculation();
			void checkCollisions();
			void update();
		private:
			std::shared_ptr<std::vector<PhysicObject>> _objects;
			int _ticks = 0;

			struct ObjectStruct {
			public:
				ObjectStruct* _next = nullptr;
				int _object = -1;

				void append(int object, Foundation::Arena<ObjectStruct>& arena)
				{
					if (_object == -1)
					{
						_object = object;
						return;
					}
					if (_next == nullptr) {
						_next = arena.alloc(1);
						*_next = ObjectStruct();
					}
					_next->append(object,arena);
				}

				void get(std::vector<int>& objects)
				{
					if (_next != nullptr)
					{
						_next->get(objects);
					}
					objects.emplace_back(_object);
				}
			};

			struct Node
			{
			public:
				Node(glm::vec3 start, glm::vec3 end);

				float _width = 0.0f;
				double _mass = 0.0;
				bool _noChilds = true;
				Node* _childs = nullptr;
				ObjectStruct* _objects = nullptr;
				int _depth = -1;
				glm::vec3 _start;
				glm::vec3 _end;
				glm::vec3 _center;
			};
			Node* _root;
			Foundation::Arena<Node> _arenaNode = Foundation::Arena<Node>(10000);
			Foundation::Arena<ObjectStruct> _arenaObject = Foundation::Arena<ObjectStruct>(40000);
			void insert();
			bool expand(Node* node,int depth);
		};
	}
}

