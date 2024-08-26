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

			PhysicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius);

			void update(float deltaTime, glm::vec3 force);
			void collision(PhysicObject& object);
			float getVelocity() { return glm::length(_velocity); }
			glm::vec3 _position;
			glm::vec3 _velocity;
			glm::vec3 _acceleration = glm::vec3(0.0, 0.0, 0.0);
			double _mass;
			float _radius;
			bool _selected = false;

		};
		void to_json(nlohmann::json& j, const PhysicObject& o);

		void from_json(const nlohmann::json& j, PhysicObject& o);
	}
	
}
