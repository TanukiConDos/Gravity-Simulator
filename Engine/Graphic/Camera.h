#pragma once
#include "SwapChain.h"
#include <glm/glm.hpp>

namespace Engine
{
	namespace Graphic
	{
		class Camera
		{
		public:

			Camera(const Camera&) = delete;
			Camera& operator=(const Camera&) = delete;

			Camera(SwapChain& swapchain);
			Camera() = default;
			glm::vec3 getDir() { return _dir; }
			glm::vec3 getUp() { return _up; }
			glm::vec3 getLeft() { return _left; }
			void transform(UniformBufferObject& ubo);
			void move(glm::vec3 translation);
			void rotate(float degrees,bool vertical);
		private:

			SwapChain& _swapchain;
			glm::vec3 _pos = { 0.0f, 0.0f, 4500.0f };
			glm::vec3 _dir = glm::normalize(glm::vec3{0.0f, 0.0f, -1.0f});
			glm::vec3 _left = glm::normalize(glm::cross(glm::vec3{ 0.0f, 1.0f, 0.0f }, _dir));
			glm::vec3 _up = glm::cross(_dir, _left);
			glm::mat4 _view;
			glm::mat4 _projection;
		};
	}
	
}


