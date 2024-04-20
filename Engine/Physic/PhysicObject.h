#pragma once
#include <glm/glm.hpp>
#include "../../External/json/json.hpp"
namespace Engine
{
	namespace Physic
	{
		class PhysicObject
		{
		public:

			PhysicObject(const PhysicObject&) = delete;
			PhysicObject& operator=(const PhysicObject&) = delete;

			static PhysicObject* physicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius) { return new PhysicObject(position, velocity, mass, radius); }

			PhysicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius);

			void update(float deltaTime, glm::vec3 force);
			void collision(PhysicObject& object);
			float getVelocity() { return glm::length(velocity); }
			glm::vec3 position;
			glm::vec3 velocity;
			double mass;
			float radius;

		private:
			
			glm::vec3 acceleration = glm::vec3(0.0,0.0,0.0);
			
		};
		void to_json(nlohmann::json& j, const PhysicObject& o);

		void from_json(const nlohmann::json& j, PhysicObject& o);
	}
	
}
