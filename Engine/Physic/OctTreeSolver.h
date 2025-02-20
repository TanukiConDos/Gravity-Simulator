#pragma once
#include "SolverInterface.h"
#include "OctTree.h"

/**
 * @file OctTreeSolver.h
 * @brief Implementa un solver de simulación física utilizando un árbol octal para resolver
 * las interacciones entre objetos físicos mediante el algoritmo Barnes-Hut.
 */

namespace Engine
{
    namespace Physic
    {
        /**
         * @class OctTreeSolver
         * @brief Solver que utiliza un árbol octal para actualizar la simulación física.
         *
         * Esta clase hereda de SolverInterface e implementa el método solve, utilizando el árbol octal
         * (_tree) para procesar y actualizar el estado de los objetos físicos en cada iteración.
         */
        class OctTreeSolver: public SolverInterface
        {
        public:
            /**
             * @brief Constructor que inicializa el solver con un árbol octal.
             *
             * @param tree Puntero compartido al OctTree que se utilizará para resolver la simulación.
             */
            explicit OctTreeSolver(std::shared_ptr<OctTree> tree) : _tree(tree) {}

            /**
             * @brief Resuelve la simulación física utilizando el árbol octal.
             *
             * Este método actualiza el estado de los objetos físicos en función del intervalo de tiempo transcurrido,
             * delegando en el árbol octal para optimizar la resolución de interacciones.
             *
             * @param deltaTime Intervalo de tiempo transcurrido.
             * @param objects Puntero compartido a un vector de objetos físicos a actualizar.
             */
            void solve(float deltaTime, std::shared_ptr<std::vector<PhysicObject>> objects) final;

        private:
            /// Puntero compartido al árbol octal empleado para resolver la simulación.
            std::shared_ptr<OctTree> _tree;
        };
    }
}


