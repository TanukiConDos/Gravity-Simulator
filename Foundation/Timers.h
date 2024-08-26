#pragma once
#include <chrono>
namespace Foundation
{
	enum class Timer
	{
		TICK,
		FRAME,
		DEBUG
	};

	class Timers
	{
	public:
		Timers(const Timers&) = delete;
		Timers& operator=(const Timers&) = delete;

		static Timers* getTimers();
		void setTimer(Timer timer, bool start);
		float getElapsedTime(Timer timer) const;
	private:
		Timers() = default;
		std::chrono::steady_clock::time_point _tick[2] = {};
		std::chrono::steady_clock::time_point _frame[2] = {};
		std::chrono::steady_clock::time_point _debug[2] = {};
	};

}

