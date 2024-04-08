#pragma once
#include "GPU.h"
#include "../Physic/PhysicObject.h"
#include "CommandPool.h"
#include "Buffer.h"
#define PI          3.141592653589793238462643383279502884f

namespace Engine
{
	namespace Graphic
	{

		class Model
		{
		public:
			Model(const Model&) = delete;
			Model& operator=(const Model&) = delete;
			Model(int sectorCount, int stackCount, GPU& gpu,CommandPool& commandPool);
			~Model();
			void bind(VkCommandBuffer commandBuffer);
			size_t getIndexSize();
		private:
			std::vector<Vertex> modelVertex = std::vector<Vertex>{};
			std::vector<int> index = std::vector<int>{};
			GPU& gpu;
			std::unique_ptr<Buffer> buffer;
		};
	}
}