#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

/**
 * @file CollisionDetectionInterface.h
 * @brief Define una interfaz para la detecci�n de colisiones en la simulaci�n f�sica.
 *
 * Este archivo declara la clase base que debe ser heredada para implementar distintos algoritmos
 * de detecci�n de colisiones entre objetos f�sicos.
 */

namespace Engine::Physic
{
	/**
	 * @class CollisionDetectionInterface
	 * @brief Interfaz para implementar algoritmos de detecci�n de colisiones.
	 *
	 * Las clases que hereden de esta interfaz deben sobrescribir el m�todo detection() para procesar
	 * la detecci�n de colisiones de acuerdo al intervalo de tiempo especificado y el conjunto de objetos f�sicos.
	 */
	class CollisionDetectionInterface
	{
	public:

		virtual ~CollisionDetectionInterface() = default;

		/**
		 * @brief Detecta colisiones entre objetos f�sicos.
		 *
		 * Este m�todo eval�a las colisiones aplicables en funci�n del intervalo de tiempo transcurrido
		 * y el vector de objetos proporcionado. Las clases derivadas deben implementar su l�gica de
		 * detecci�n de colisiones en este m�todo.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos f�sicos a evaluar.
		 */
		virtual void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) = 0;
	};
}