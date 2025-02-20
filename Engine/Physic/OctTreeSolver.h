#pragma once
#include "SolverInterface.h"
#include "OctTree.h"

/**
 * @file OctTreeSolver.h
 * @brief Implementa un solver de simulaci�n f�sica utilizando un �rbol octal para resolver
 * las interacciones entre objetos f�sicos mediante el algoritmo Barnes-Hut.
 */

namespace Engine
{
    namespace Physic
    {
        /**
         * @class OctTreeSolver
         * @brief Solver que utiliza un �rbol octal para actualizar la simulaci�n f�sica.
         *
         * Esta clase hereda de SolverInterface e implementa el m�todo solve, utilizando el �rbol octal
         * (_tree) para procesar y actualizar el estado de los objetos f�sicos en cada iteraci�n.
         */
        class OctTreeSolver: public SolverInterface
        {
        public:
            /**
             * @brief Constructor que inicializa el solver con un �rbol octal.
             *
             * @param tree Puntero compartido al OctTree que se utilizar� para resolver la simulaci�n.
             */
            explicit OctTreeSolver(std::shared_ptr<OctTree> tree) : _tree(tree) {}

            /**
             * @brief Resuelve la simulaci�n f�sica utilizando el �rbol octal.
             *
             * Este m�todo actualiza el estado de los objetos f�sicos en funci�n del intervalo de tiempo transcurrido,
             * delegando en el �rbol octal para optimizar la resoluci�n de interacciones.
             *
             * @param deltaTime Intervalo de tiempo transcurrido.
             * @param objects Puntero compartido a un vector de objetos f�sicos a actualizar.
             */
            void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;

        private:
            /// Puntero compartido al �rbol octal empleado para resolver la simulaci�n.
            std::shared_ptr<OctTree> _tree;
        };
    }
}


