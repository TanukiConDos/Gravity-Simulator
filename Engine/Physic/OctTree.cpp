#include "OctTree.h"

namespace Engine
{
	namespace Physic
	{
		OctTree::OctTree(std::shared_ptr<std::vector<PhysicObject*>> objects): objects(objects)
		{
			insert();
		}

		void OctTree::checkCollisions()
		{
			for (PhysicObject* object : *objects)
			{
				Node* current = &root;

				while (current != nullptr)
				{
					for (PhysicObject* object2 : current->objects)
					{
						if (object == object2) continue;
						object->collision(*object2);
					}
					glm::dvec3 pos = object->getPosition();
					double radius = object->getRadius();
					bool childFound = false;
					for (Node* child: current->childs)
					{
						if (child == nullptr) continue;
						if (child->start[0] < pos[0] - radius
							|| child->start[1] < pos[1] - radius
							|| child->start[2] < pos[2] - radius
							|| child->end[0] > pos[0] + radius
							|| child->end[1] > pos[1] + radius
							|| child->end[2] > pos[2] + radius)
						{
							current = child;
							childFound = true;
							continue;
						}
					}
					if (!childFound) current = nullptr;
				}
			}
		}

		void OctTree::update()
		{
			if (ticks > 100)
			{
				ticks = 0;
				for (Node* child : root.childs)
				{
					child = nullptr;
				}
				root.objects.clear();
				insert();
			}
			ticks++;
		}

		void OctTree::insert()
		{
			for (PhysicObject* object : *objects)
			{
				std::stack<Node*> stack;
				stack.emplace(&root);
				while (!stack.empty())
				{
					Node* current = stack.top();
					stack.pop();
					if (current->objects.size() == 0)
					{
						current->objects.emplace_back(object);
						continue;
					}
					glm::dvec3 pos = object->getPosition();
					double radius = object->getRadius();
					for (Node* child: current->childs)
					{
						if (child == nullptr) continue;
						if (child->start[0] < pos[0] - radius
							|| child->start[1] < pos[1] - radius
							|| child->start[2] < pos[2] - radius
							|| child->end[0] > pos[0] + radius
							|| child->end[1] > pos[1] + radius
							|| child->end[2] > pos[2] + radius)
						{
							stack.emplace(child);
						}
					}
					if (current->numChilds == 8)
					{
						current->objects.emplace_back(object);
						continue;
					}
					glm::dvec3 newEnd = glm::dvec3{ (current->start[0] + current->end[0]) / 2,(current->start[1] + current->end[1]) / 2,(current->start[2] + current->end[2]) / 2 };
					glm::dvec3 minPos = object->getPosition() - object->getRadius();
					glm::dvec3 maxPos = object->getPosition() + object->getRadius();
					if (maxPos[0] < newEnd[0] || maxPos[1] < newEnd[1] || maxPos[2] < newEnd[2])
					{
						current->childs[0] = new Node(current->start, newEnd);
						stack.emplace(current->childs[0]);
						//checkObjects();
					}
					if ((maxPos[0] < newEnd[0] || maxPos[1] < newEnd[1] || minPos[2] > newEnd[2]) && current->numChilds < 8)
					{
						current->childs[1] = new Node(glm::dvec3{ current->start[0],current->start[1],newEnd[2] }, glm::dvec3{ newEnd[0],newEnd[1],current->end[2] });
						stack.emplace(current->childs[1]);
						//checkObjects();
					}
					if ((maxPos[0] < newEnd[0] || minPos[1] > newEnd[1] || maxPos[2] < newEnd[2]) && current->numChilds < 8)
					{
						current->childs[2] = new Node(glm::dvec3{ current->start[0],newEnd[1],current->start[2] }, glm::dvec3{ newEnd[0],current->end[1],newEnd[2] });
						stack.emplace(current->childs[2]);
						//checkObjects();
					}
					if ((maxPos[0] < newEnd[0] || minPos[1] > newEnd[1] || minPos[2] > newEnd[2]) && current->numChilds < 8)
					{
						current->childs[3] = new Node(glm::dvec3{ current->start[0],newEnd[1],newEnd[2] }, glm::dvec3{ newEnd[0],current->end[1],current->end[2] });
						stack.emplace(current->childs[3]);
						//checkObjects();
					}
					if ((minPos[0] > newEnd[0] || maxPos[1] < newEnd[1] || maxPos[2] < newEnd[2]) && current->numChilds < 8)
					{
						current->childs[4] = new Node(glm::dvec3{ newEnd[0],current->start[1],current->start[2] }, glm::dvec3{ current->end[0],newEnd[1],newEnd[2] });
						stack.emplace(current->childs[4]);
						//checkObjects();
					}
					if ((minPos[0] > newEnd[0] || maxPos[1] < newEnd[1] || minPos[2] > newEnd[2]) && current->numChilds < 8)
					{
						current->childs[5] = new Node(glm::dvec3{ newEnd[0],current->start[1],newEnd[2] }, glm::dvec3{ current->end[0],newEnd[1],current->end[2] });
						stack.emplace(current->childs[5]);
						//checkObjects();
					}
					if ((minPos[0] > newEnd[0] || minPos[1] > newEnd[1] || maxPos[2] < newEnd[2]) && current->numChilds < 8)
					{
						current->childs[6] = new Node(glm::dvec3{ newEnd[0],newEnd[1],current->start[2] }, glm::dvec3{ current->end[0],current->end[1],newEnd[2] });
						stack.emplace(current->childs[6]);
						//checkObjects();
					}
					if ((minPos[0] > newEnd[0] || minPos[1] > newEnd[1] || minPos[2] > newEnd[2]) && current->numChilds < 8)
					{
						current->childs[7] = new Node(newEnd, current->end);
						stack.emplace(current->childs[7]);
						//checkObjects();
					}
				}
			}
		}

		OctTree::Node::Node(glm::dvec3 start, glm::dvec3 end): start(start), end(end)
		{
			for (Node* child : childs) child = nullptr;
		}

		void OctTree::Node::checkObjects()
		{
			for (PhysicObject* object : objects)
			{
				glm::dvec3 pos = object->getPosition();
				double radius = object->getRadius();
				for (int i = 0; i < numChilds; i++)
				{
					if (childs[i]->start[0] < pos[0] - radius
						&& childs[i]->start[1] < pos[1] - radius
						&& childs[i]->start[2] < pos[2] - radius
						&& childs[i]->end[0] > pos[0] + radius
						&& childs[i]->end[1] > pos[1] + radius
						&& childs[i]->end[2] > pos[2] + radius)
					{
						//childs[i]->addObject(*object);
					}
				}
			}
		}
	}
}