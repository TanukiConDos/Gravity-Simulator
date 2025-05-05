#include "Camera.h"
namespace Engine::Graphic
{
	Camera::Camera(SwapChain& swapchain): _swapchain(swapchain)
	{
		_view = glm::lookAt(_pos, _pos + _dir, glm::vec3{ 0.0f, 1.0f, 0.0f });

		VkExtent2D extent = swapchain.getExtent();
		_projection = glm::perspective(glm::radians(70.0f), extent.width / (float)extent.height, 0.1f, std::numeric_limits<float>::max());
	}
	void Camera::transform(UniformBufferObject& ubo) const
	{
		ubo.view = _view;
		ubo.proj = _projection;
	}

	void Camera::move(glm::vec3 translation)
	{
		_pos += translation;
		_view = glm::lookAt(_pos, _pos + _dir, glm::vec3{ 0.0f, 1.0f, 0.0f });
	}
	void Camera::rotate(float degrees, bool vertical)
	{
		glm::vec3 axis = vertical ? -_left : _up;

		_dir = glm::rotate(glm::mat4(1.0f), glm::radians(degrees), axis) * glm::vec4(_dir, 1.0f);
		_dir = glm::normalize(_dir);
		_left = glm::normalize(glm::cross(glm::vec3{ 0.0f, 1.0f, 0.0f }, _dir));
		_view = glm::lookAt(_pos, _pos + _dir, glm::vec3{ 0.0f, 1.0f, 0.0f });
	}
}

