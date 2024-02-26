#pragma once
#include "SwapChain.h"
#include "DescriptorPool.h"

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
			void transform(UniformBufferObject& ubo);
		private:

			SwapChain& swapchain;
			glm::dmat4 view;
			glm::dmat4 projection;
		};
	}
	
}


