#include "Camera.h"
namespace Engine::Graphic
{
	Camera::Camera(SwapChain& swapchain): swapchain(swapchain)
	{
		view = glm::lookAt(pos, pos + dir, glm::vec3{ 0.0f, 1.0f, 0.0f });

		VkExtent2D extent = swapchain.getExtent();
		projection = glm::perspective(glm::radians(70.0f), extent.width / (float)extent.height, 0.1f, std::numeric_limits<float>::max());
	}
	void Camera::transform(UniformBufferObject& ubo)
	{
		ubo.view = view;
		ubo.proj = projection;
	}

	void Camera::move(glm::vec3 translation)
	{
		pos += translation;
		view = glm::lookAt(pos, pos + dir, glm::vec3{ 0.0f, 1.0f, 0.0f });
	}
	void Camera::rotate(float degrees, bool vertical)
	{
		glm::vec3 axis = vertical ? glm::vec3{ 1.0f, 0.0f, 0.0f } : glm::vec3{ 0.0f, 1.0f, 0.0f };

		dir = glm::rotate(glm::mat4(1.0f), glm::radians(degrees), axis) * glm::vec4(dir, 1.0f);
		dir = glm::normalize(dir);

		view = glm::lookAt(pos, pos + dir, glm::vec3{ 0.0f, 1.0f, 0.0f });
	}
}

