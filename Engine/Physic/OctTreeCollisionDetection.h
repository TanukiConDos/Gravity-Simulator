/**
 * @file OctTreeCollisionDetection.h
 * @brief Implementa una detección de colisiones utilizando un árbol octal (OctTree) para optimizar la simulación.
 *
 * Esta implementación hereda de CollisionDetectionInterface y utiliza un puntero compartido a un OctTree para gestionar
 * la detección de colisiones entre objetos físicos.
 */

#pragma once
#include "CollisionDetectionInterface.h"
#include "OctTree.h"

namespace Engine
{
	namespace Physic
	{
		/**
		 * @class OctTreeCollisionDetection
		 * @brief Implementación concreta de detección de colisiones basada en un árbol octal.
		 *
		 * La clase utiliza un puntero compartido a un OctTree para procesar la detección de colisiones en la simulación,
		 * mejorando la eficiencia respecto a métodos de fuerza bruta.
		 */
		class OctTreeCollisionDetection : public CollisionDetectionInterface
		{
		public:
			/**
			 * @brief Constructor que inicializa el detector con un árbol octal.
			 *
			 * @param tree Puntero compartido al OctTree que se empleará para la detección de colisiones.
			 */
			explicit OctTreeCollisionDetection(std::shared_ptr<OctTree> tree): _tree(tree) {}

			/**
			 * @brief Detecta colisiones entre objetos físicos utilizando el árbol octal.
			 *
			 * Este método utiliza el OctTree asociado para evaluar las colisiones entre los objetos, 
			 * basándose en el intervalo de tiempo transcurrido.
			 *
			 * @param deltaTime Intervalo de tiempo transcurrido.
			 * @param objects Puntero compartido a un vector de objetos físicos a evaluar.
			 */
			void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
		private:
			/// Puntero compartido al árbol octal empleado para la detección de colisiones.
			std::shared_ptr<OctTree> _tree;
		};
	}
}

