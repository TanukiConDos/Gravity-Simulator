/**
 * @file OctTreeCollisionDetection.h
 * @brief Implementa una detecci�n de colisiones utilizando un �rbol octal (OctTree) para optimizar la simulaci�n.
 *
 * Esta implementaci�n hereda de CollisionDetectionInterface y utiliza un puntero compartido a un OctTree para gestionar
 * la detecci�n de colisiones entre objetos f�sicos.
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
		 * @brief Implementaci�n concreta de detecci�n de colisiones basada en un �rbol octal.
		 *
		 * La clase utiliza un puntero compartido a un OctTree para procesar la detecci�n de colisiones en la simulaci�n,
		 * mejorando la eficiencia respecto a m�todos de fuerza bruta.
		 */
		class OctTreeCollisionDetection : public CollisionDetectionInterface
		{
		public:
			/**
			 * @brief Constructor que inicializa el detector con un �rbol octal.
			 *
			 * @param tree Puntero compartido al OctTree que se emplear� para la detecci�n de colisiones.
			 */
			explicit OctTreeCollisionDetection(std::shared_ptr<OctTree> tree): _tree(tree) {}

			/**
			 * @brief Detecta colisiones entre objetos f�sicos utilizando el �rbol octal.
			 *
			 * Este m�todo utiliza el OctTree asociado para evaluar las colisiones entre los objetos, 
			 * bas�ndose en el intervalo de tiempo transcurrido.
			 *
			 * @param deltaTime Intervalo de tiempo transcurrido.
			 * @param objects Puntero compartido a un vector de objetos f�sicos a evaluar.
			 */
			void detection(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;
		private:
			/// Puntero compartido al �rbol octal empleado para la detecci�n de colisiones.
			std::shared_ptr<OctTree> _tree;
		};
	}
}

