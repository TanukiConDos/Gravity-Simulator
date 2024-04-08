#include "OctTree.h"
#include <chrono>
namespace Engine
{
	namespace Physic
	{
		OctTree::OctTree(std::shared_ptr<std::vector<PhysicObject*>> objects): objects(objects)
		{
			insert();
			massCalculation();
		}

		void OctTree::barnesHut(double deltaTime)
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
					double distance = glm::distance(current->center, object->getPosition());
					if ( current->width / distance < 0.1 && distance > 0)
					{
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->getMass() * current->mass) / (distance * distance)) * (glm::dvec3)glm::normalize(object->getPosition() - current->center));
						continue;
					}
					if (current->noChilds && current->object != nullptr)
					{
						if (current->object == object) continue;
						distance = glm::distance(current->object->getPosition(), object->getPosition());
						totalForce = totalForce + (glm::vec3)(((-PhysicSystem::UNIVERSAL_GRAVITATION * object->getMass() * current->object->getMass()) / (distance * distance)) * (glm::dvec3)glm::normalize(object->getPosition() - current->object->getPosition()));
						continue;
					}

					for (Node* child : current->childs)
					{
						if (child->noChilds && child->object == nullptr) continue;
						stack.emplace(child);
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
				if (current->object != nullptr){
					current->mass = current->object->getMass();
					continue;
				}

				stack2.emplace(current);
				for (Node* child : current->childs)
				{
					if (child->noChilds && child->object == nullptr) continue;
					stack.emplace(child);
				}
			}

			while (!stack2.empty())
			{
				Node* current = stack2.top();
				stack2.pop();
				for (Node* child : current->childs)
				{
					current->mass += child->mass;
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
					
					if (current->object != nullptr)
					{
						if (object == current->object) continue;
						object->collision(*current->object);
					}
					

					glm::vec3 pos = object->getPosition();
					float radius = object->getRadius();
					glm::vec3 minPos = pos - radius;
					glm::vec3 maxPos = pos + radius;
					if (current->noChilds) continue;
					for (Node* child: current->childs)
					{
						if (child->noChilds && child->object == nullptr) continue;
						if (glm::all(glm::lessThanEqual(child->start, maxPos))
							|| glm::all(glm::greaterThan(child->end, minPos)))
						{
							stack.emplace(child);
						}
					}
				}
			}
		}

		void OctTree::update()
		{
			if (ticks > 500)
			{
				ticks = 0;
				root = new Node(glm::vec3{ -1.1e11 , -1.1e11 , -1.1e11 },
					glm::vec3{ 1.1e11, 1.1e11, 1.1e11 });
				insert();
			}
			ticks++;
		}

		void OctTree::insert()
		{
			for (PhysicObject* object : *objects)
			{
				Node* current = root;
				glm::vec3 pos = object->getPosition();
				while (true)
				{
					if (current->noChilds) break;
					for (Node* child : current->childs)
					{
						if (child == nullptr) continue;
						if (glm::all(glm::lessThanEqual(child->start, pos))
							&& glm::all(glm::greaterThan(child->end, pos)))
						{
							current = child;
							break;
						}
					}
				}
				if (current->object == nullptr) {
					current->object = object;
					continue;
				}

				current->expand();
				PhysicObject* object2 = current->object;
				current->object = nullptr;
				glm::vec pos2 = object2->getPosition();
				int bothInserted = 0;
				while (bothInserted < 2)
				{
					for (Node* child : current->childs)
					{
						if (glm::all(glm::lessThanEqual(child->start, pos))
							&& glm::all(glm::greaterThan(child->end, pos)))
						{
							if (glm::all(glm::lessThanEqual(child->start, pos2))
								&& glm::all(glm::greaterThan(child->end, pos2)))
							{
								child->expand();
								current = child;
								break;
							}
							child->object = object;
							bothInserted++;
						}
						if (glm::all(glm::lessThanEqual(child->start, pos2))
							&& glm::all(glm::greaterThan(child->end, pos2)))
						{
							child->object = object2;
							bothInserted++;
						}
						if (bothInserted == 2) break;
					}
				}
			}
		}

		OctTree::Node::Node(glm::vec3 start, glm::vec3 end): start(start), end(end)
		{
			center = glm::vec3{ (start[0] + end[0]) / 2,(start[1] + end[1]) / 2,(start[2] + end[2]) / 2 };
			width = end[0] - start[0];
		}

		void OctTree::Node::expand()
		{
			this->noChilds = false;
			childs[0] = new Node(start, center);
			childs[1] = new Node(glm::vec3{ start[0],start[1],center[2] }, glm::vec3{ center[0], center[1], end[2] });
			childs[2] = new Node(glm::vec3{ start[0], center[1], start[2] }, glm::vec3{ center[0], end[1], center[2] });
			childs[3] = new Node(glm::vec3{ start[0], center[1], center[2] }, glm::vec3{ center[0], end[1], end[2] });
			childs[4] = new Node(glm::vec3{ center[0], start[1], start[2] }, glm::vec3{ end[0], center[1], center[2] });
			childs[5] = new Node(glm::vec3{ center[0], start[1], center[2] }, glm::vec3{ end[0], center[1], end[2] });
			childs[6] = new Node(glm::vec3{ center[0], center[1], start[2] }, glm::vec3{ end[0], end[1], center[2] });
			childs[7] = new Node(center, end);
		}
	}
}