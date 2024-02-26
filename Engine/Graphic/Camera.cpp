#include "Camera.h"
namespace Engine::Graphic
{
	Camera::Camera(SwapChain& swapchain): swapchain(swapchain)
	{
		view = glm::lookAt(glm::dvec3(0.0f, 0.0f, 9000.0f), glm::dvec3{ 0,0,0 }, glm::dvec3(1.0f, 0.0f, 0.0f));

		VkExtent2D extent = swapchain.getExtent();
		projection = glm::perspective(glm::radians(90.0f), extent.width / (float)extent.height, 0.1f, std::numeric_limits<float>::max());
	}
	void Camera::transform(UniformBufferObject& ubo)
	{
		ubo.view = view;
		ubo.proj = projection;
	}
}

