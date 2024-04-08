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

			static PhysicObject* physicObject(glm::vec3 position, glm::vec3 velocity, glm::vec3 acceleration, float mass, float radius) { return new PhysicObject(position, velocity, acceleration, mass, radius); }

			PhysicObject(glm::vec3 position, glm::vec3 velocity, glm::vec3 acceleration, float mass, float radius);

			void update(float deltaTime, glm::vec3 force);
			void collision(PhysicObject& object);
			glm::vec3 getPosition() { return position; }
			double getMass() { return mass; }
			float getVelocity() { return glm::length(velocity); }
			float getRadius() { return radius; }
		private:
			glm::vec3 position;
			glm::vec3 velocity;
			glm::vec3 acceleration;
			double mass;
			float radius;
		};
	}
	
}
