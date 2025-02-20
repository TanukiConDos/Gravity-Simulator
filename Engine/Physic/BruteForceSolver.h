#pragma once
#include "SolverInterface.h"
#include "PhysicSystem.h"
#include <iostream>
#include <vector>

/**
 * @file BruteForceSolver.h
 * @brief Implementa un solver de simulación física usando el enfoque de fuerza bruta.
 *
 * Esta clase actualiza los objetos físicos procesándolos de forma iterativa, evaluando todas las interacciones de fuerza.
 */

namespace Engine::Physic
{
	/**
	 * @class BruteForceSolver
	 * @brief Solver que utiliza el método de fuerza bruta para actualizar la simulación física.
	 *
	 * Hereda de SolverInterface e implementa el método solve, procesando las interacciones entre objetos
	 * de forma iterativa para actualizar sus estados.
	 */
	class BruteForceSolver: public SolverInterface
	{
	public:
		/**
		 * @brief Resuelve la simulación física mediante fuerza bruta.
		 *
		 * Este método recorre el vector de objetos físicos y aplica la lógica necesaria para actualizar
		 * sus estados en función del intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos físicos a resolver.
		 */
		void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


