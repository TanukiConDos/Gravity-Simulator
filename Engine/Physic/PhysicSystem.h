/**
 * @file PhysicSystem.h
 * @brief Gestiona la simulaci�n f�sica utilizando un algoritmo de detecci�n de colisiones y un solver para actualizar los estados de los objetos.
 *
 * La constante UNIVERSAL_GRAVITATION se puede utilizar en los c�lculos de fuerzas gravitacionales en la simulaci�n.
 */

#pragma once
#include "CollisionDetectionInterface.h"
#include "SolverInterface.h"
#include <iostream>

 /**
  * @namespace Engine::Physic
  * @brief Espacio de nombres que contiene las clases del motor de f�sicas.
  */
namespace Engine::Physic
{
	/**
	 * @class PhysicSystem
	 * @brief Sistema f�sico encargado de actualizar la simulaci�n mediante la detecci�n de colisiones y la resoluci�n de fuerzas.
	 *
	 * La clase utiliza una instancia de CollisionDetectionInterface para detectar colisiones entre objetos f�sicos y una
	 * instancia de SolverInterface para resolver las interacciones y actualizar el estado de dichos objetos.
	 */
	class PhysicSystem
	{
	public:
		/// Constante de gravitaci�n universal utilizada en los c�lculos f�sicos.
		static const float UNIVERSAL_GRAVITATION;

		/**
		 * @brief Actualiza la simulaci�n f�sica.
		 *
		 * Este m�todo ejecuta la detecci�n de colisiones y, posteriormente, utiliza el solver para resolver las interacciones
		 * entre los objetos f�sicos, bas�ndose en el intervalo de tiempo transcurrido.
		 *
		 * @param deltaTime Intervalo de tiempo transcurrido.
		 * @param objects Puntero compartido a un vector de objetos f�sicos a actualizar.
		 */
		void update(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects);

		/**
		 * @brief Constructor que inicializa el sistema f�sico.
		 *
		 * Recibe instancias �nicas de algoritmos para la detecci�n de colisiones y resoluci�n, que ser�n utilizados en la simulaci�n.
		 *
		 * @param narrowCollitionDetectionAlgorithm Instancia �nica del algoritmo de detecci�n de colisiones.
		 * @param solverAlgorithm Instancia �nica del algoritmo que resuelve la simulaci�n f�sica.
		 */
		PhysicSystem(std::unique_ptr<CollisionDetectionInterface> narrowCollitionDetectionAlgorithm, std::unique_ptr<SolverInterface> solverAlgorithm);
		
		PhysicSystem() = default;
	private:
		/// Algoritmo de detecci�n de colisiones utilizado en la simulaci�n.
		std::unique_ptr<CollisionDetectionInterface> _collitionDetectionAlgorithm;
		/// Algoritmo solver utilizado para actualizar los estados de los objetos f�sicos.
		std::unique_ptr<SolverInterface> _solverAlgorithm;
	};
}

