#pragma once
#include <chrono>
namespace Foundation
{
	enum Timer
	{
		TICK,
		FRAME
	};

	class Timers
	{
	public:
		Timers(const Timers&) = delete;
		Timers& operator=(const Timers&) = delete;

		static Timers* getTimers();
		void setTimer(Timer timer, bool start);
		float getElapsedTime(Timer timer);
	private:
		Timers() = default;
		std::chrono::steady_clock::time_point tick[2] = {};
		std::chrono::steady_clock::time_point frame[2] = {};
	};

}

