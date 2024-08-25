#include "OctTree.h"
#include <chrono>
#include "../../Foundation/Config.h"
#include "../../Foundation/Timers.h"
namespace Engine
{
	namespace Physic
	{
		OctTree::OctTree(std::shared_ptr<std::vector<PhysicObject>> objects): 
			_objects(objects)
		{
			_root = _arenaNode.alloc(1);
			*_root = Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 }, glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
			insert();
			if(Foundation::Config::getConfig()->SolverAlgorithm == Foundation::Algorithm::OCTREE) massCalculation();
		}

		void OctTree::barnesHut(float deltaTime)
		{
			for (int objectId = 0; objectId < _objects->size(); objectId++)
			{
				PhysicObject* object = &_objects->at(objectId);
				glm::vec3 totalForce = {0,0,0};
				std::stack<Node*> stack;
				stack.emplace(_root);
				while (!stack.empty())
				{
					Node* current = stack.top();
					stack.pop();
					double distance = glm::distance(current->_center, object->_position);
					if ( current->_width / distance < 1 && distance > 0)
					{
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->_mass * current->_mass) / (distance * distance)) * (glm::dvec3)glm::normalize(object->_position - current->_center));
						continue;
					}

					if (current->_noChilds && current->_objects != nullptr)
					{
						std::vector<int> nodeObjects;
						current->_objects->get(nodeObjects);
						for (int objectId2 = 0; objectId2 < nodeObjects.size(); objectId2++)
						{
							if (objectId2 == objectId) continue;
							PhysicObject* object2 = &_objects->at(objectId2);
							distance = glm::distance(object2->_position, object->_position);
							totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->_mass * object2->_mass) / (distance * distance)) * (glm::dvec3)glm::normalize(object->_position - object2->_position));
						}
						continue;
					}

					for (int i = 0; i < 8; i++)
					{
						if (current->_childs[i]._noChilds && current->_childs[i]._objects == nullptr) continue;
						stack.emplace(current->_childs + i);
					}
				}
				object->update(deltaTime, totalForce);
			}
		}

		void OctTree::massCalculation()
		{
			std::stack<Node*> stack, stack2;
			stack.emplace(_root);
			while (!stack.empty())
			{
				Node* current = stack.top();
				stack.pop();
				if (current->_objects != nullptr){
					double aux = 0.0;
					std::vector<int> nodeObjects;
					current->_objects->get(nodeObjects);
					for (int objectId2 = 0; objectId2 < nodeObjects.size(); objectId2++)
					{
						aux += _objects->at(objectId2)._mass;
					}
					current->_mass = aux;
					continue;
				}

				stack2.emplace(current);
				for (int i = 0; i < 8; i++)
				{
					if (current->_childs[i]._noChilds && current->_childs[i]._objects == nullptr) continue;
					stack.emplace(current->_childs + i);
				}
			}

			while (!stack2.empty())
			{
				Node* current = stack2.top();
				stack2.pop();
				for (int i = 0; i < 8; i++)
				{
					current->_mass += current->_childs[i]._mass;
				}
			}
		}

		void OctTree::checkCollisions()
		{
			for (int objectId = 0; objectId < _objects->size(); objectId++)
			{
				PhysicObject* object = &_objects->at(objectId);
				std::stack<Node*> stack;
				stack.emplace(_root);
				while (!stack.empty())
				{
					Node* current = stack.top();
					stack.pop();
					if (current->_objects != nullptr)
					{
						std::vector<int> nodeObjects;
						current->_objects->get(nodeObjects);
						for (int objectId2 = 0; objectId2 < nodeObjects.size(); objectId2++)
						{
							if (objectId == objectId2) continue;
							object->collision(_objects->at(objectId2));
						}
					}
					
					if (current->_noChilds) continue;

					glm::vec3 minPos = object->_position - object->_radius;
					glm::vec3 maxPos = object->_position + object->_radius;
					for (int i = 0; i < 8; i++)
					{
						if (current->_childs[i]._noChilds && current->_childs[i]._objects == nullptr) continue;
						if (glm::all(glm::lessThanEqual(current->_childs[i]._start, maxPos))
							|| glm::all(glm::greaterThan(current->_childs[i]._end, minPos)))
						{
							stack.emplace(current->_childs + i);
						}
					}
				}
			}
		}

		void OctTree::update()
		{

			if (_ticks > 10)
			{
				_ticks = 0;
				_arenaNode.clear();
				_arenaObject.clear();
				_root = _arenaNode.alloc(1);
				*_root = Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 },
					glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
				insert();
				if (Foundation::Config::getConfig()->SolverAlgorithm == Foundation::Algorithm::OCTREE) massCalculation();
			}
			_ticks++;
		}

		void OctTree::insert()
		{
			for (int objectId = 0; objectId < _objects->size(); objectId++)
			{
				Node* current = _root;
				glm::vec3 pos = _objects->at(objectId)._position;
				int depth = 0;
				int depthCmp = 0;
				while (true)
				{
					if (current->_noChilds) break;
					for (int i = 0; i < 8; i++)
					{
						if (current->_childs + i == nullptr) continue;
						if (glm::all(glm::lessThanEqual(current->_childs[i]._start, pos))
							&& glm::all(glm::greaterThan(current->_childs[i]._end, pos)))
						{
							current = current->_childs + i;
							depth++;
							break;
						}
					}
					if (depth == depthCmp) break;
					depthCmp++;
				}
				if (current->_objects == nullptr) {
					current->_objects = _arenaObject.alloc(1);
					*current->_objects = ObjectStruct();
					current->_objects->append(objectId,_arenaObject);
					continue;
				}
				
				if (expand(current, depth))
				{
					std::vector<int> nodeObjects;
					current->_objects->get(nodeObjects);
					nodeObjects.emplace_back(objectId);
					for (int objectId2 = 0; objectId2 < nodeObjects.size(); objectId2++)
					{
						glm::vec3 pos2 = _objects->at(objectId2)._position;
						for (int i = 0; i < 8; i++)
						{
							if (glm::all(glm::lessThanEqual(current->_childs[i]._start, pos2))
								&& glm::all(glm::greaterThan(current->_childs[i]._end, pos2)))
							{
								if (current->_childs[i]._objects == nullptr)
								{
									current->_childs[i]._objects = _arenaObject.alloc(1);
									*current->_childs[i]._objects = ObjectStruct();
								}
								current->_childs[i]._objects->append(objectId2,_arenaObject);
								break;
							}
						}
					}
				}
				else
				{
					current->_objects->append(objectId,_arenaObject);
				}

				current->_objects = nullptr;
				
			}
		}

		OctTree::Node::Node(glm::vec3 start, glm::vec3 end): _start(start), _end(end)
		{
			_center = glm::vec3{ (start[0] + end[0]) / 2,(start[1] + end[1]) / 2,(start[2] + end[2]) / 2 };
			_width = end[0] - start[0];
		}

		bool OctTree::expand(Node* node,int depth)
		{
			if (depth > 3) return false;
			node->_noChilds = false;
			node->_childs = _arenaNode.alloc(8);
			node->_childs[0] = Node(node->_start, node->_center);
			node->_childs[1] = Node(glm::vec3{ node->_start[0],node->_start[1],node->_center[2] }, glm::vec3{ node->_center[0], node->_center[1], node->_end[2] });
			node->_childs[2] = Node(glm::vec3{ node->_start[0], node->_center[1], node->_start[2] }, glm::vec3{ node->_center[0], node->_end[1], node->_center[2] });
			node->_childs[3] = Node(glm::vec3{ node->_start[0], node->_center[1], node->_center[2] }, glm::vec3{ node->_center[0], node->_end[1], node->_end[2] });
			node->_childs[4] = Node(glm::vec3{ node->_center[0], node->_start[1], node->_start[2] }, glm::vec3{ node->_end[0], node->_center[1], node->_center[2] });
			node->_childs[5] = Node(glm::vec3{ node->_center[0], node->_start[1], node->_center[2] }, glm::vec3{ node->_end[0], node->_center[1], node->_end[2] });
			node->_childs[6] = Node(glm::vec3{ node->_center[0], node->_center[1], node->_start[2] }, glm::vec3{ node->_end[0], node->_end[1], node->_center[2] });
			node->_childs[7] = Node(node->_center, node->_end);
			return true;
		}
	}
}