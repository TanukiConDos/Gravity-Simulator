#include "Model.h"
namespace Engine::Graphic
{
	Model::Model(int sectorCount, int stackCount,GPU& gpu,CommandPool& commandPool): gpu(gpu)
	{
		float x, y, z, xy;                              // vertex position
		float radius = 1.0f;
		float sectorStep = 2 * PI / sectorCount;
		float stackStep = PI / stackCount;
		float sectorAngle, stackAngle;

		for (int i = 0; i <= stackCount; ++i)
		{
			stackAngle = PI / 2 - i * stackStep;        // starting from pi/2 to -pi/2
			xy = radius * cosf(stackAngle);             // r * cos(u)
			z = radius * sinf(stackAngle);              // r * sin(u)

			// add (sectorCount+1) vertices per stack
			// first and last vertices have same position and normal, but different tex coords
			for (int j = 0; j <= sectorCount; ++j)
			{
				sectorAngle = j * sectorStep;           // starting from 0 to 2pi

				// vertex position (x, y, z)
				x = xy * cosf(sectorAngle);             // r * cos(u) * cos(v)
				y = xy * sinf(sectorAngle);             // r * cos(u) * sin(v)
				glm::vec3 color;
				color = glm::vec3{ x,y,z };
				modelVertex.push_back(Vertex{ glm::vec3{x,y,z},color });
			}
		}
		// generate CCW index list of sphere triangles
		// k1--k1+1
		// |  / |
		// | /  |
		// k2--k2+1
		int k1, k2;
		for (int i = 0; i < stackCount; ++i)
		{
			k1 = i * (sectorCount + 1);     // beginning of current stack
			k2 = k1 + sectorCount + 1;      // beginning of next stack

			for (int j = 0; j < sectorCount; ++j, ++k1, ++k2)
			{
				// 2 triangles per sector excluding first and last stacks
				// k1 => k2 => k1+1
				if (i != 0)
				{
					index.push_back(k1);
					index.push_back(k2);
					index.push_back(k1 + 1);
				}

				// k1+1 => k2 => k2+1
				if (i != (stackCount - 1))
				{
					index.push_back(k1 + 1);
					index.push_back(k2);
					index.push_back(k2 + 1);
				}
			}
		}
		VkDeviceSize vertexSize = sizeof(modelVertex[0]) * static_cast<uint32_t>(modelVertex.size());
		VkDeviceSize indexSize = sizeof(index[0]) * static_cast<uint32_t>(index.size());
		VkDeviceSize bufferSize = vertexSize + indexSize;

		buffer = std::make_unique<Buffer>(gpu,
			bufferSize,
			VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

		Buffer stagingBuffer{ gpu,
			bufferSize, 
			VK_BUFFER_USAGE_TRANSFER_SRC_BIT, 
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT };

		stagingBuffer.map();
		stagingBuffer.writeData((void*)modelVertex.data(), vertexSize);
		stagingBuffer.writeData((void*)index.data(), indexSize, vertexSize);

		VkCommandBuffer commandBuffer = commandPool.createTemporalCommandBuffer();
		gpu.copyBuffer(stagingBuffer.getBuffer(), buffer->getBuffer(), bufferSize, commandBuffer);
		commandPool.endTemporalCommandBuffer(commandBuffer);
	}

	Model::~Model()
	{
	}

	void Model::bind(VkCommandBuffer commandBuffer)
	{
		VkBuffer vertexBuffers[] = { buffer->getBuffer()};
		VkDeviceSize offsets[] = { 0 };
		vkCmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, offsets);
		vkCmdBindIndexBuffer(commandBuffer, buffer->getBuffer(), sizeof(modelVertex[0]) * modelVertex.size() , VK_INDEX_TYPE_UINT32);
	}

	size_t Model::getIndexSize()
	{
		return index.size();
	}

}