#pragma once
#include <fstream>
#include <string>
#include <vector>



namespace Foundation
{
	class File
	{
	public:
		File(std::string filename);
		~File();
		size_t getSize() { return size; };
		std::vector<char> read();

	private:
		std::ifstream file;
		size_t size;
	};

}

