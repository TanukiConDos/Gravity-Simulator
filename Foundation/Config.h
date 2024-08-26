#pragma once
#include <map>
#include <string>

namespace Foundation
{
	enum class Algorithm
	{
		BRUTE_FORCE = 0,
		OCTREE = 1
	};
	
	enum class Mode
	{
		RANDOM = 0,
		FILE = 1
	};

	class Config
	{
	public:
		Config(const Config&) = delete;
		Config& operator=(const Config&) = delete;
		static Config* getConfig();
		Mode systemCreationMode = Mode::FILE;
		int numObjects = 998;
		float time = 1000;
		char fichero[100] = "tierra.json";
		Algorithm collisionAlgorithm = Algorithm::BRUTE_FORCE;
		Algorithm SolverAlgorithm = Algorithm::BRUTE_FORCE;
	private:
		Config() = default;
		
	};
}

