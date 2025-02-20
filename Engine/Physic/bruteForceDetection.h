/**
 * @file bruteForceDetection.h
 * @brief Implementa la detección de colisiones utilizando el método de fuerza bruta.
 *
 * Esta clase hereda de CollisionDetectionInterface y sobreescribe el método detection para evaluar 
 * las colisiones entre objetos físicos de manera iterativa.
 */

#pragma once
#include "CollisionDetectionInterface.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	/**
	 * @class bruteForceDetection
	 * @brief Detección de colisiones mediante fuerza bruta.
	 *
	 * Esta clase implementa el método detection utilizando un enfoque de fuerza bruta, recorriendo
	 * iterativamente el vector de objetos físicos para identificar colisiones en función del intervalo 
	 * de tiempo transcurrido.
	 */
	class bruteForceDetection : public CollisionDetectionInterface
	{
	public:
		/**
		 * @brief Detecta colisiones entre objetos físicos.
		 *
		 * Este método evalúa todas las posibles interacciones entre los objetos utilizando un 
		 * enfoque de fuerza bruta, considerando el intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos físicos a evaluar.
		 */
		void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


