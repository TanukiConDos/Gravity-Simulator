/**
 * @file bruteForceDetection.h
 * @brief Implementa la detecci�n de colisiones utilizando el m�todo de fuerza bruta.
 *
 * Esta clase hereda de CollisionDetectionInterface y sobreescribe el m�todo detection para evaluar 
 * las colisiones entre objetos f�sicos de manera iterativa.
 */

#pragma once
#include "CollisionDetectionInterface.h"
#include <memory>
#include <vector>

namespace Engine::Physic
{
	/**
	 * @class bruteForceDetection
	 * @brief Detecci�n de colisiones mediante fuerza bruta.
	 *
	 * Esta clase implementa el m�todo detection utilizando un enfoque de fuerza bruta, recorriendo
	 * iterativamente el vector de objetos f�sicos para identificar colisiones en funci�n del intervalo 
	 * de tiempo transcurrido.
	 */
	class bruteForceDetection : public CollisionDetectionInterface
	{
	public:
		/**
		 * @brief Detecta colisiones entre objetos f�sicos.
		 *
		 * Este m�todo eval�a todas las posibles interacciones entre los objetos utilizando un 
		 * enfoque de fuerza bruta, considerando el intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos f�sicos a evaluar.
		 */
		void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
	};
}


