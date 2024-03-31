#pragma once
#include <glm/glm.hpp>

namespace Engine
{
	namespace Physic
	{
		class PhysicObject
		{
		public:

			PhysicObject(const PhysicObject&) = delete;
			PhysicObject& operator=(const PhysicObject&) = delete;

			static PhysicObject* physicObject(glm::dvec3 position, glm::dvec3 velocity, glm::dvec3 acceleration, double mass, double radius) { return new PhysicObject(position, velocity, acceleration, mass, radius); }

			PhysicObject(glm::dvec3 position, glm::dvec3 velocity, glm::dvec3 acceleration, double mass, double radius);

			void update(double deltaTime, glm::dvec3 force);
			void collision(PhysicObject& object);
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
	
}
