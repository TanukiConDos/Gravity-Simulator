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
		if (mass == 7.35e25)
		{
			std::cout << "acc: " << acceleration[0] / 1000 << " " << acceleration[1] / 1000 << " " << acceleration[2] / 1000 << std::endl;
			std::cout << "vel: " << velocity[0] / 1000 << " " << velocity[1] / 1000 << " " << velocity[2] / 1000 << std::endl;
		}
		
	}
	void PhysicObject::collision(PhysicObject object)
	{
		if (radius + object.radius > glm::distance(position, object.position))
		{
			double intersection = radius + object.radius - glm::distance(position, object.position);
			glm::dvec3 distanceVec = position - object.position;
			glm::dvec3 move = glm::normalize(distanceVec) * intersection;
			position = position + move;
			acceleration = { 0,0,0 };
			velocity = { 0,0,0 };
		}
	}
}