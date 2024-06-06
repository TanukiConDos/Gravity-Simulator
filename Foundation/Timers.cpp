#include "Timers.h"
namespace Foundation
{
	Timers* Timers::getTimers()
	{
		static Timers instance;
		return &instance;
	}

	void Foundation::Timers::setTimer(Timer timer, bool start)
	{
		switch (timer)
		{
		case Timer::FRAME:
			if (start) frame[0] = std::chrono::high_resolution_clock::now();
			else frame[1] = std::chrono::high_resolution_clock::now();
			break;
		case Timer::TICK:
			if (start) tick[0] = std::chrono::high_resolution_clock::now();
			else tick[1] = std::chrono::high_resolution_clock::now();
			break;
		case Timer::DEBUG:
			if (start) debug[0] = std::chrono::high_resolution_clock::now();
			else debug[1] = std::chrono::high_resolution_clock::now();
			break;
		}
	}
	float Timers::getElapsedTime(Timer timer)
	{
		float elapsedTime = 0;
		switch (timer)
		{
		case Timer::FRAME:
			elapsedTime = std::chrono::duration<float, std::milli>(frame[1] - frame[0]).count();
			break;
		case Timer::TICK:
			elapsedTime = std::chrono::duration<float, std::milli>(tick[1] - tick[0]).count();
			break;
		case Timer::DEBUG:
			elapsedTime = std::chrono::duration<float, std::milli>(debug[1] - debug[0]).count();
			break;
		}

		return elapsedTime;
	}
}

