#include "File.h"


namespace Foundation
{
	File::File(std::string filename)
	{
		file.open(filename, std::ios::ate | std::ios::binary);

		if (!file.is_open()) {
			throw std::runtime_error("failed to open file!");
		}

		size = (size_t)file.tellg();

		file.seekg(0);
	}
	File::~File()
	{
		file.close();
	}
	std::vector<char> File::read()
	{
		std::vector<char> buffer(size);
		file.read(buffer.data(), size);
		file.seekg(0);
		return buffer;
	}
}

