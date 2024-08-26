#include "File.h"


namespace Foundation
{
	File::File(std::string const &filename,bool isShader)
	{
		if (isShader) file.open(filename, std::ios::in | std::ios::ate | std::ios::binary);
		else file.open(filename, std::ios::out | std::ios::in | std::ios::ate);
		if (!file.is_open()) {
			if(isShader) throw std::runtime_error("failed to open file!");
			std::ofstream outfile(filename);

			outfile << "";

			outfile.close();
			file.open(filename, std::ios::out | std::ios::in | std::ios::ate);
			if (!file.is_open()) throw std::runtime_error("failed to open file!");
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
	void File::write(std::string const & data)
	{
		file.clear();
		file.write(data.c_str(),data.size());
	}
}

