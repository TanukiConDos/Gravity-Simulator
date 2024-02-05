#pragma once
#include <glm/glm.hpp>

namespace Engine::Physic
{
	class PhysicObject
	{
	public:

		PhysicObject(glm::dvec3 position, glm::dvec3 velocity, glm::dvec3 acceleration, double mass, double radius);

		void update(double deltaTime,glm::dvec3 force);
		void collision(PhysicObject object);
		glm::dvec3 getPosition() { return position; }
		double getMass() { return mass; }
		double getVelocity() { return glm::length(velocity); }
		double getRadius() { return radius; }
	private:
		glm::dvec3 position;
		glm::dvec3 velocity;
		glm::dvec3 acceleration;
		double mass;
		double radius;
	};
}
