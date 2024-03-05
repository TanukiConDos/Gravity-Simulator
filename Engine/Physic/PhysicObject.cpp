#include "PhysicObject.h"
#include <iostream>
namespace Engine::Physic
{
	PhysicObject::PhysicObject(glm::dvec3 position, glm::dvec3 velocity, glm::dvec3 acceleration, double mass, double radius): position(position),velocity(velocity),acceleration(acceleration),mass(mass),radius(radius)
	{
	}

	void PhysicObject::update(double deltaTime, glm::dvec3 force)
	{
		deltaTime = deltaTime;
		this->acceleration = force / mass;
		this->position = position + ((velocity * deltaTime) + 0.5 * acceleration * (deltaTime * deltaTime));
		this->velocity = velocity + (acceleration * deltaTime);
	}
	void PhysicObject::collision(PhysicObject& object)
	{
		if (radius + object.radius > glm::distance(position, object.position))
		{
			double intersection = radius + object.radius - glm::distance(position, object.position);
			glm::dvec3 distanceVec = position - object.position;
			glm::dvec3 move = glm::normalize(distanceVec) * intersection;
			position = position + move;
			if (glm::length(velocity) - glm::length(object.velocity) > 1000)
			{
				velocity += object.velocity;
				object.velocity = velocity;
			}
			
		}
	}
}