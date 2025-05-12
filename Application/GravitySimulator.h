/**
 * @file GravitySimulator.h
 * @brief Header para la simulación de gravedad.
 */

#pragma once

#include <iostream>
#include <stdexcept>
#include <thread>
#include <random>

#include "Window.h"
#include "../Engine/Graphic/Renderer.h"
#include "../Engine/Physic/PhysicSystem.h"
#include "../External/enkiTS/TaskScheduler.h"

/**
 * @namespace Application
 * @brief Espacio de nombres que contiene la aplicación y sus componentes.
 */
namespace Application
{
    /**
     * @class GravitySimulator
     * @brief Clase principal para la simulación de gravedad.
     *
     * Se encarga de inicializar, ejecutar y finalizar la simulación, gestionando
     * la ventana, objetos físicos, renderizado y el sistema de estados.
     */
    class GravitySimulator
    {
    public:
        /// Ancho de la ventana.
        const int WIDTH = 1280;
        /// Alto de la ventana.
        const int HEIGHT = 720;

        /**
         * @brief Constructor por defecto de GravitySimulator.
         */
        GravitySimulator();

        /**
         * @brief Inicializa la simulación.
         *
         * Configura la ventana, los objetos físicos y demás componentes necesarios.
         */
        void initSimulation();

        /**
         * @brief Finaliza la simulación.
         *
         * Libera recursos y finaliza la ejecución de la simulación.
         */
        void endSimulation();

        /**
         * @brief Ejecuta la simulación.
         *
         * Inicia el bucle principal de actualización de la física y el renderizado.
         */
        void run();

    private:
        /// Instancia de la ventana de la aplicación.
        Window _window = Window{ WIDTH, HEIGHT };
        /// Colección de objetos físicos participantes en la simulación.
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();
        /// Renderizador gráfico encargado de dibujar la simulación.
        std::unique_ptr<Engine::Graphic::Renderer> _renderer;
        /// Sistema físico que gestiona las interacciones y simulaciones.
        Engine::Physic::PhysicSystem _physicSystem;
        /// Máquina de estados para gestionar el flujo de la simulación.
        std::shared_ptr<StateMachine> _stateMachine = StateMachine::getStateMachine();

        /// Scheduler para la gestión de tareas en paralelo.
		enki::TaskScheduler _taskScheduler;
        /// Tiempo transcurrido para cada frame.
        float _frameTime = 0;
        /// Tiempo de tick del sistema.
        float _tickTime = 0;
        /// Simulacion en proceso de terminar.
		bool _end = false;

        /// Simulacion terminada.
        bool _ended = false;
		/// Simulacion esta terminando.
		std::condition_variable _endSync;
		/// Simulacion ha terminando.
        std::condition_variable _endedSync;
		/// Mutex para la sincronización de finalización.
        std::mutex _endMutex;
		/// Mutex para la sincronización de finalización.
        std::mutex _endedMutex;


    };

} // namespace Application
