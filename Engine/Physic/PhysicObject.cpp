#include "PhysicObject.h"
#include <iostream>
namespace Engine::Physic
{
	PhysicObject::PhysicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius): _position(position),_velocity(velocity),_mass(mass),_radius(radius)
	{
	}

	void PhysicObject::update(float deltaTime, glm::vec3 force)
	{
		deltaTime = deltaTime;
		this->_acceleration = force / (float)_mass;
		this->_position = _position + ((_velocity * deltaTime) + 0.5f * _acceleration * (deltaTime * deltaTime));
		this->_velocity = _velocity + (_acceleration * deltaTime);
	}
	void PhysicObject::collision(PhysicObject& object)
	{
		if (_radius + object._radius > glm::distance(_position, object._position))
		{
			float intersection = _radius + object._radius - glm::distance(_position, object._position);
			glm::vec3 distanceVec = _position - object._position;
			glm::vec3 move = glm::normalize(distanceVec) * intersection;
			_position = _position + move;
			if (glm::length(_velocity) - glm::length(object._velocity) > 1000)
			{
				_velocity += object._velocity;
				object._velocity = _velocity;
			}
			
		}
	}
	void to_json(nlohmann::json& j, const PhysicObject& o)
	{
		j = nlohmann::json{
			{"position", {o._position[0], o._position[1], o._position[2]}},
			{"velocity", {o._velocity[0], o._velocity[1], o._velocity[2]}},
			{"mass", o._mass},
			{"radius", o._radius}
		};
	}
	void from_json(const nlohmann::json& j, PhysicObject& o)
	{
		j.at("position").at(0).get_to(o._position[0]);
		j.at("position").at(1).get_to(o._position[1]);
		j.at("position").at(2).get_to(o._position[2]);
		j.at("velocity").at(0).get_to(o._velocity[0]);
		j.at("velocity").at(1).get_to(o._velocity[1]);
		j.at("velocity").at(2).get_to(o._velocity[2]);
		j.at("mass").get_to(o._mass);
		j.at("radius").get_to(o._radius);
	}
}