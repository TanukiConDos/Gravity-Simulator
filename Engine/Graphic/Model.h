#pragma once
#include "GPU.h"
#include "../Physic/PhysicObject.h"
#include "CommandPool.h"
#include "Buffer.h"
const double PI = 3.141592653589793238462643383279502884f;

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
			void bind(VkCommandBuffer commandBuffer) const;
			size_t getIndexSize();
		private:
			std::vector<Vertex> _modelVertex = std::vector<Vertex>{};
			std::vector<int> _index = std::vector<int>{};
			GPU& _gpu;
			std::unique_ptr<Buffer> _buffer;
		};
	}
}