#include "PhysicObject.h"
#include <iostream>
namespace Engine::Physic
{
	PhysicObject::PhysicObject(glm::vec3 position, glm::vec3 velocity, glm::vec3 acceleration, float mass, float radius): position(position),velocity(velocity),acceleration(acceleration),mass(mass),radius(radius)
	{
	}

	void PhysicObject::update(float deltaTime, glm::vec3 force)
	{
		deltaTime = deltaTime;
		this->acceleration = force / (float)mass;
		this->position = position + ((velocity * deltaTime) + 0.5f * acceleration * (deltaTime * deltaTime));
		this->velocity = velocity + (acceleration * deltaTime);
	}
	void PhysicObject::collision(PhysicObject& object)
	{
		if (radius + object.radius > glm::distance(position, object.position))
		{
			float intersection = radius + object.radius - glm::distance(position, object.position);
			glm::vec3 distanceVec = position - object.position;
			glm::vec3 move = glm::normalize(distanceVec) * intersection;
			position = position + move;
			if (glm::length(velocity) - glm::length(object.velocity) > 1000)
			{
				velocity += object.velocity;
				object.velocity = velocity;
			}
			
		}
	}
}