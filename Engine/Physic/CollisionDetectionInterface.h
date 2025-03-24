#pragma once
#include "PhysicObject.h"
#include <memory>
#include <vector>

/**
 * @file CollisionDetectionInterface.h
 * @brief Define una interfaz para la detección de colisiones en la simulación física.
 *
 * Este archivo declara la clase base que debe ser heredada para implementar distintos algoritmos
 * de detección de colisiones entre objetos físicos.
 */

namespace Engine::Physic
{
	/**
	 * @class CollisionDetectionInterface
	 * @brief Interfaz para implementar algoritmos de detección de colisiones.
	 *
	 * Las clases que hereden de esta interfaz deben sobrescribir el método detection() para procesar
	 * la detección de colisiones de acuerdo al intervalo de tiempo especificado y el conjunto de objetos físicos.
	 */
	class CollisionDetectionInterface
	{
	public:

		virtual ~CollisionDetectionInterface() = default;

		/**
		 * @brief Detecta colisiones entre objetos físicos.
		 *
		 * Este método evalúa las colisiones aplicables en función del intervalo de tiempo transcurrido
		 * y el vector de objetos proporcionado. Las clases derivadas deben implementar su lógica de
		 * detección de colisiones en este método.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos físicos a evaluar.
		 */
		virtual void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) = 0;
	};
}