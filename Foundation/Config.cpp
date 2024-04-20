#include "Config.h"
#include "File.h"
namespace Foundation
{
	Config* Config::getConfig()
	{
		static Config instance;
		return &instance;
	}
}

