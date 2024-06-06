#include "OctTree.h"
#include <chrono>
#include "../../Foundation/Config.h"
#include "../../Foundation/Timers.h"
namespace Engine
{
	namespace Physic
	{
		OctTree::OctTree(std::shared_ptr<std::vector<PhysicObject*>> objects): 
			objects(objects)
		{
			root = arenaNode.alloc(1);
			*root = Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 }, glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
			insert();
			if(Foundation::Config::getConfig()->SolverAlgorithm == Foundation::Algorithm::OCTREE) massCalculation();
		}

		void OctTree::barnesHut(float deltaTime)
		{
			for (PhysicObject* object : *objects)
			{
				glm::vec3 totalForce = {0,0,0};
				std::stack<Node*> stack;
				stack.emplace(root);
				while (!stack.empty())
				{
					Node* current = stack.top();
					stack.pop();
					double distance = glm::distance(current->center, object->position);
					if ( current->width / distance < 1 && distance > 0)
					{
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->mass * current->mass) / (distance * distance)) * (glm::dvec3)glm::normalize(object->position - current->center));
						continue;
					}

					if (current->noChilds && current->objects != nullptr)
					{
						std::vector<PhysicObject*> nodeObjects;
						current->objects->get(nodeObjects);
						for (PhysicObject* object2 : nodeObjects)
						{
							if (object2 == object) continue;
							distance = glm::distance(object2->position, object->position);
							totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->mass * object2->mass) / (distance * distance)) * (glm::dvec3)glm::normalize(object->position - object2->position));
						}
						continue;
					}

					for (int i = 0; i < 8; i++)
					{
						if (current->childs[i].noChilds && current->childs[i].objects == nullptr) continue;
						stack.emplace(current->childs + i);
					}
				}
				object->update(deltaTime, totalForce);
			}
		}

		void OctTree::massCalculation()
		{
			std::stack<Node*> stack, stack2;
			stack.emplace(root);
			while (!stack.empty())
			{
				Node* current = stack.top();
				stack.pop();
				if (current->objects != nullptr){
					double aux = 0.0;
					std::vector<PhysicObject*> nodeObjects;
					current->objects->get(nodeObjects);
					for (PhysicObject* object2 : nodeObjects)
					{
						aux += object2->mass;
					}
					current->mass = aux;
					continue;
				}

				stack2.emplace(current);
				for (int i = 0; i < 8; i++)
				{
					if (current->childs[i].noChilds && current->childs[i].objects == nullptr) continue;
					stack.emplace(current->childs + i);
				}
			}

			while (!stack2.empty())
			{
				Node* current = stack2.top();
				stack2.pop();
				for (int i = 0; i < 8; i++)
				{
					current->mass += current->childs[i].mass;
				}
			}
		}

		void OctTree::checkCollisions()
		{
			for (PhysicObject* object : *objects)
			{
				std::stack<Node*> stack;
				stack.emplace(root);
				while (!stack.empty())
				{
					Node* current = stack.top();
					stack.pop();
					if (current->objects != nullptr)
					{
						std::vector<PhysicObject*> nodeObjects;
						current->objects->get(nodeObjects);
						for (PhysicObject* object2 : nodeObjects)
						{
							if (object == object2) continue;
							object->collision(*object2);
						}
					}
					
					if (current->noChilds) continue;

					glm::vec3 minPos = object->position - object->radius;
					glm::vec3 maxPos = object->position + object->radius;
					for (int i = 0; i < 8; i++)
					{
						if (current->childs[i].noChilds && current->childs[i].objects == nullptr) continue;
						if (glm::all(glm::lessThanEqual(current->childs[i].start, maxPos))
							|| glm::all(glm::greaterThan(current->childs[i].end, minPos)))
						{
							stack.emplace(current->childs + i);
						}
					}
				}
			}
		}

		void OctTree::update()
		{

			if (ticks > 10)
			{
				ticks = 0;
				arenaNode.clear();
				arenaObject.clear();
				root = arenaNode.alloc(1);
				*root = Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 },
					glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
				insert();
				if (Foundation::Config::getConfig()->SolverAlgorithm == Foundation::Algorithm::OCTREE) massCalculation();
			}
			ticks++;
		}

		void OctTree::insert()
		{
			for (PhysicObject* object : *objects)
			{
				Node* current = root;
				glm::vec3 pos = object->position;
				int depth = 0;
				while (true)
				{
					if (current->noChilds) break;
					for (int i = 0; i < 8; i++)
					{
						if (current->childs + i == nullptr) continue;
						if (glm::all(glm::lessThanEqual(current->childs[i].start, pos))
							&& glm::all(glm::greaterThan(current->childs[i].end, pos)))
						{
							current = current->childs + i;
							depth++;
							break;
						}
					}
				}
				if (current->objects == nullptr) {
					current->objects = arenaObject.alloc(1);
					*current->objects = ObjectStruct();
					current->objects->append(object,arenaObject);
					continue;
				}
				
				if (expand(current, depth))
				{
					std::vector<PhysicObject*> nodeObjects;
					current->objects->get(nodeObjects);
					nodeObjects.emplace_back(object);
					for (PhysicObject* object2 : nodeObjects)
					{
						glm::vec3 pos2 = object2->position;
						for (int i = 0; i < 8; i++)
						{
							if (glm::all(glm::lessThanEqual(current->childs[i].start, pos2))
								&& glm::all(glm::greaterThan(current->childs[i].end, pos2)))
							{
								if (current->childs[i].objects == nullptr)
								{
									current->childs[i].objects = arenaObject.alloc(1);
									*current->childs[i].objects = ObjectStruct();
								}
								current->childs[i].objects->append(object2,arenaObject);
								break;
							}
						}
					}
				}
				else
				{
					current->objects->append(object,arenaObject);
				}

				current->objects = nullptr;
				
			}
		}

		OctTree::Node::Node(glm::vec3 start, glm::vec3 end): start(start), end(end)
		{
			center = glm::vec3{ (start[0] + end[0]) / 2,(start[1] + end[1]) / 2,(start[2] + end[2]) / 2 };
			width = end[0] - start[0];
		}

		bool OctTree::expand(Node* node,int depth)
		{
			if (depth > 2) return false;
			node->noChilds = false;
			node->childs = arenaNode.alloc(8);
			node->childs[0] = Node(node->start, node->center);
			node->childs[1] = Node(glm::vec3{ node->start[0],node->start[1],node->center[2] }, glm::vec3{ node->center[0], node->center[1], node->end[2] });
			node->childs[2] = Node(glm::vec3{ node->start[0], node->center[1], node->start[2] }, glm::vec3{ node->center[0], node->end[1], node->center[2] });
			node->childs[3] = Node(glm::vec3{ node->start[0], node->center[1], node->center[2] }, glm::vec3{ node->center[0], node->end[1], node->end[2] });
			node->childs[4] = Node(glm::vec3{ node->center[0], node->start[1], node->start[2] }, glm::vec3{ node->end[0], node->center[1], node->center[2] });
			node->childs[5] = Node(glm::vec3{ node->center[0], node->start[1], node->center[2] }, glm::vec3{ node->end[0], node->center[1], node->end[2] });
			node->childs[6] = Node(glm::vec3{ node->center[0], node->center[1], node->start[2] }, glm::vec3{ node->end[0], node->end[1], node->center[2] });
			node->childs[7] = Node(node->center, node->end);
			return true;
		}
	}
}