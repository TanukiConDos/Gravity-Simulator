#pragma once
#include <map>
#include <string>

namespace Foundation
{
	enum Algorithm
	{
		BRUTE_FORCE,
		OCTREE
	};
	
	enum Mode
	{
		RANDOM,
		FILE
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

