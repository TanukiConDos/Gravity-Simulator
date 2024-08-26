#pragma once
#include <fstream>
#include <string>
#include <vector>



namespace Foundation
{
	class File
	{
	public:
		File(const File&) = delete;
		File& operator=(const File&) = delete;

		File(std::string const &filename, bool isShader = true);
		~File();
		size_t getSize() const { return size; };
		std::vector<char> read();
		void write(std::string const & data);

	private:
		std::fstream file;
		size_t size;
	};

}

