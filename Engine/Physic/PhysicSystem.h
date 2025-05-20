/**
 * @file PhysicSystem.h
 * @brief Gestiona la simulación física utilizando un algoritmo de detección de colisiones y un solver para actualizar los estados de los objetos.
 *
 * La constante UNIVERSAL_GRAVITATION se puede utilizar en los cálculos de fuerzas gravitacionales en la simulación.
 */

#pragma once
#include "CollisionDetectionInterface.h"
#include "SolverInterface.h"
#include <iostream>

 /**
  * @namespace Engine::Physic
  * @brief Espacio de nombres que contiene las clases del motor de físicas.
  */
namespace Engine::Physic
{
	/**
	 * @class PhysicSystem
	 * @brief Sistema físico encargado de actualizar la simulación mediante la detección de colisiones y la resolución de fuerzas.
	 *
	 * La clase utiliza una instancia de CollisionDetectionInterface para detectar colisiones entre objetos físicos y una
	 * instancia de SolverInterface para resolver las interacciones y actualizar el estado de dichos objetos.
	 */
	class PhysicSystem
	{
	public:
		/// Constante de gravitación universal utilizada en los cálculos físicos.
		static const float UNIVERSAL_GRAVITATION;

		/**
		 * @brief Actualiza la simulación física.
		 *
		 * Este método ejecuta la detección de colisiones y, posteriormente, utiliza el solver para resolver las interacciones
		 * entre los objetos físicos, basándose en el intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos físicos a actualizar.
		 */
		void update(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects);

		/**
		 * @brief Constructor que inicializa el sistema físico.
		 *
		 * Recibe instancias únicas de algoritmos para la detección de colisiones y resolución, que serán utilizados en la simulación.
		 *
		 * @param narrowCollitionDetectionAlgorithm Instancia única del algoritmo de detección de colisiones.
		 * @param solverAlgorithm Instancia única del algoritmo que resuelve la simulación física.
		 */
		PhysicSystem(std::unique_ptr<CollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<SolverInterface> solverAlgorithm);
		
		PhysicSystem() = default;
	private:
		/// Algoritmo de detección de colisiones utilizado en la simulación.
		std::unique_ptr<CollisionDetectionInterface> _collitionDetectionAlgorithm;
		/// Algoritmo solver utilizado para actualizar los estados de los objetos físicos.
		std::unique_ptr<SolverInterface> _solverAlgorithm;
	};
}

