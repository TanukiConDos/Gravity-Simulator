#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

/**
 * @file SolverInterface.h
 * @brief Define una interfaz para implementar m�todos de resoluci�n de la simulaci�n f�sica.
 *
 * Esta interfaz declara el m�todo solve, que debe ser implementado por las clases derivadas para actualizar
 * y resolver las interacciones entre objetos f�sicos en funci�n del delta de tiempo.
 */

namespace Engine::Physic
{
	/**
	 * @class SolverInterface
	 * @brief Interfaz para resolver la simulaci�n f�sica.
	 *
	 * Las clases derivadas deben implementar el m�todo solve para actualizar los estados de los objetos f�sicos.
	 */
	class SolverInterface
	{
	public:

		virtual ~SolverInterface() = default;

		/**
		 * @brief Resuelve la simulaci�n f�sica.
		 *
		 * Este m�todo procesa la simulaci�n a partir del intervalo de tiempo especificado
		 * y actualiza el conjunto de objetos f�sicos.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos f�sicos a resolver.
		 */
		virtual void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) = 0;
	};
}
