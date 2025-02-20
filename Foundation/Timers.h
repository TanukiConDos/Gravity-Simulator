/**
 * @file Timers.h
 * @brief Proporciona utilidades de temporización para varios procesos, como tiempos de tick, frame y depuración.
 */

#pragma once
#include <chrono>

/**
 * @namespace Foundation
 * @brief Contiene utilidades y clases fundamentales utilizadas en toda la aplicación.
 */
namespace Foundation
{
	/**
	 * @enum Timer
	 * @brief Enumera los diferentes temporizadores usados en la aplicación.
	 */
	enum class Timer
	{
		TICK,   ///< Temporizador usado para ticks del sistema.
		FRAME,  ///< Temporizador usado para la medición de tiempos de frame.
		DEBUG   ///< Temporizador usado con fines de depuración.
	};

	/**
	 * @class Timers
	 * @brief Clase singleton que administra distintos temporizadores para mediciones de rendimiento.
	 *
	 * Esta clase proporciona métodos para iniciar/detener temporizadores y obtener el tiempo transcurrido para eventos específicos.
	 */
	class Timers
	{
	public:
		Timers(const Timers&) = delete;
		Timers& operator=(const Timers&) = delete;

		/**
		 * @brief Recupera la instancia singleton de Timers.
		 * @return Timers* Puntero a la instancia singleton.
		 */
		static Timers* getTimers();

		/**
		 * @brief Inicia o detiene un temporizador especificado.
		 *
		 * @param timer El temporizador a controlar.
		 * @param start true para iniciar el temporizador, false para detenerlo.
		 */
		void setTimer(Timer timer, bool start);

		/**
		 * @brief Obtiene el tiempo transcurrido de un temporizador.
		 *
		 * @param timer El temporizador para el cual se desea obtener el tiempo transcurrido.
		 * @return float El tiempo transcurrido en segundos.
		 */
		float getElapsedTime(Timer timer) const;
	private:
		/**
		 * @brief Constructor privado para asegurar el patrón singleton.
		 */
		Timers() = default;
		/// Puntos de tiempo para el temporizador de tick.
		std::chrono::steady_clock::time_point _tick[2] = {};
		/// Puntos de tiempo para el temporizador de frame.
		std::chrono::steady_clock::time_point _frame[2] = {};
		/// Puntos de tiempo para el temporizador de depuración.
		std::chrono::steady_clock::time_point _debug[2] = {};
	};

} // namespace Foundation

