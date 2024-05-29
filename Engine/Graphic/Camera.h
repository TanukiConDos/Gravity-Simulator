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
			glm::vec3 getDir() { return dir; }
			glm::vec3 getUp() { return up; }
			glm::vec3 getLeft() { return left; }
			void transform(UniformBufferObject& ubo);
			void move(glm::vec3 translation);
			void rotate(float degrees,bool vertical);
		private:

			SwapChain& swapchain;
			glm::vec3 pos = { 0.0f, 0.0f, 4500.0f };
			glm::vec3 dir = glm::normalize(glm::vec3{0.0f, 0.0f, -1.0f});
			glm::vec3 left = glm::normalize(glm::cross(glm::vec3{ 0.0f, 1.0f, 0.0f }, dir));
			glm::vec3 up = glm::cross(dir, left);
			glm::mat4 view;
			glm::mat4 projection;
		};
	}
	
}


