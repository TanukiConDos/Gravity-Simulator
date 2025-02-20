#pragma once
#include "SolverInterface.h"
#include "PhysicSystem.h"
#include <iostream>
#include <vector>

/**
 * @file BruteForceSolver.h
 * @brief Implementa un solver de simulaci�n f�sica usando el enfoque de fuerza bruta.
 *
 * Esta clase actualiza los objetos f�sicos proces�ndolos de forma iterativa, evaluando todas las interacciones de fuerza.
 */

namespace Engine::Physic
{
	/**
	 * @class BruteForceSolver
	 * @brief Solver que utiliza el m�todo de fuerza bruta para actualizar la simulaci�n f�sica.
	 *
	 * Hereda de SolverInterface e implementa el m�todo solve, procesando las interacciones entre objetos
	 * de forma iterativa para actualizar sus estados.
	 */
	class BruteForceSolver: public SolverInterface
	{
	public:
		/**
		 * @brief Resuelve la simulaci�n f�sica mediante fuerza bruta.
		 *
		 * Este m�todo recorre el vector de objetos f�sicos y aplica la l�gica necesaria para actualizar
		 * sus estados en funci�n del intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos f�sicos a resolver.
		 */
		void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


