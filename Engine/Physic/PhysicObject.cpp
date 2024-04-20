#include "PhysicObject.h"
#include <iostream>
namespace Engine::Physic
{
	PhysicObject::PhysicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius): position(position),velocity(velocity),mass(mass),radius(radius)
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
	void to_json(nlohmann::json& j, const PhysicObject& o)
	{
		j = nlohmann::json{
			{"position", {o.position[0], o.position[1], o.position[2]}},
			{"velocity", {o.velocity[0], o.velocity[1], o.velocity[2]}},
			{"mass", o.mass},
			{"radius", o.radius}
		};
	}
	void from_json(const nlohmann::json& j, PhysicObject& o)
	{
		j.at("position").at(0).get_to(o.position[0]);
		j.at("position").at(1).get_to(o.position[1]);
		j.at("position").at(2).get_to(o.position[2]);
		j.at("velocity").at(0).get_to(o.velocity[0]);
		j.at("velocity").at(1).get_to(o.velocity[1]);
		j.at("velocity").at(2).get_to(o.velocity[2]);
		j.at("mass").get_to(o.mass);
		j.at("radius").get_to(o.radius);
	}
}