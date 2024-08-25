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
			if (start) _frame[0] = std::chrono::high_resolution_clock::now();
			else _frame[1] = std::chrono::high_resolution_clock::now();
			break;
		case Timer::TICK:
			if (start) _tick[0] = std::chrono::high_resolution_clock::now();
			else _tick[1] = std::chrono::high_resolution_clock::now();
			break;
		case Timer::DEBUG:
			if (start) _debug[0] = std::chrono::high_resolution_clock::now();
			else _debug[1] = std::chrono::high_resolution_clock::now();
			break;
		}
	}
	float Timers::getElapsedTime(Timer timer)
	{
		float elapsedTime = 0;
		switch (timer)
		{
		case Timer::FRAME:
			elapsedTime = std::chrono::duration<float, std::milli>(_frame[1] - _frame[0]).count();
			break;
		case Timer::TICK:
			elapsedTime = std::chrono::duration<float, std::milli>(_tick[1] - _tick[0]).count();
			break;
		case Timer::DEBUG:
			elapsedTime = std::chrono::duration<float, std::milli>(_debug[1] - _debug[0]).count();
			break;
		}

		return elapsedTime;
	}
}

