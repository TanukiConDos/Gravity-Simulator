#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

/**
 * @file SolverInterface.h
 * @brief Define una interfaz para implementar métodos de resolución de la simulación física.
 *
 * Esta interfaz declara el método solve, que debe ser implementado por las clases derivadas para actualizar
 * y resolver las interacciones entre objetos físicos en función del delta de tiempo.
 */

namespace Engine::Physic
{
	/**
	 * @class SolverInterface
	 * @brief Interfaz para resolver la simulación física.
	 *
	 * Las clases derivadas deben implementar el método solve para actualizar los estados de los objetos físicos.
	 */
	class SolverInterface
	{
	public:

		virtual ~SolverInterface() = default;

		/**
		 * @brief Resuelve la simulación física.
		 *
		 * Este método procesa la simulación a partir del intervalo de tiempo especificado
		 * y actualiza el conjunto de objetos físicos.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos físicos a resolver.
		 */
		virtual void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) = 0;
	};
}
