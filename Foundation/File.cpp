#include "File.h"


namespace Foundation
{
	File::File(std::string const &filename,bool isShader)
	{
		if (isShader) _file.open(filename, std::ios::in | std::ios::ate | std::ios::binary);
		else _file.open(filename, std::ios::out | std::ios::in | std::ios::ate);
		if (!_file.is_open()) {
			if(isShader) throw std::runtime_error("failed to open file!");
			std::ofstream outfile(filename);

			outfile << "";

			outfile.close();
			_file.open(filename, std::ios::out | std::ios::in | std::ios::ate);
			if (!_file.is_open()) throw std::runtime_error("failed to open file!");
		}

		_size = (size_t)_file.tellg();

		_file.seekg(0);
	}
	File::~File()
	{
		_file.close();
	}
	std::vector<char> File::read()
	{
		std::vector<char> buffer(_size);
		_file.read(buffer.data(), _size);
		_file.seekg(0);
		return buffer;
	}
	void File::write(std::string const & data)
	{
		_file.clear();
		_file.write(data.c_str(),data.size());
	}
}

