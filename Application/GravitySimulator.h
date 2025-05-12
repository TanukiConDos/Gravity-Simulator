/**
 * @file GravitySimulator.h
 * @brief Header para la simulaci�n de gravedad.
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
 * @brief Espacio de nombres que contiene la aplicaci�n y sus componentes.
 */
namespace Application
{
    /**
     * @class GravitySimulator
     * @brief Clase principal para la simulaci�n de gravedad.
     *
     * Se encarga de inicializar, ejecutar y finalizar la simulaci�n, gestionando
     * la ventana, objetos f�sicos, renderizado y el sistema de estados.
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
         * @brief Inicializa la simulaci�n.
         *
         * Configura la ventana, los objetos f�sicos y dem�s componentes necesarios.
         */
        void initSimulation();

        /**
         * @brief Finaliza la simulaci�n.
         *
         * Libera recursos y finaliza la ejecuci�n de la simulaci�n.
         */
        void endSimulation();

        /**
         * @brief Ejecuta la simulaci�n.
         *
         * Inicia el bucle principal de actualizaci�n de la f�sica y el renderizado.
         */
        void run();

    private:
        /// Instancia de la ventana de la aplicaci�n.
        Window _window = Window{ WIDTH, HEIGHT };
        /// Colecci�n de objetos f�sicos participantes en la simulaci�n.
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();
        /// Renderizador gr�fico encargado de dibujar la simulaci�n.
        std::unique_ptr<Engine::Graphic::Renderer> _renderer;
        /// Sistema f�sico que gestiona las interacciones y simulaciones.
        Engine::Physic::PhysicSystem _physicSystem;
        /// M�quina de estados para gestionar el flujo de la simulaci�n.
        std::shared_ptr<StateMachine> _stateMachine = StateMachine::getStateMachine();

        /// Scheduler para la gesti�n de tareas en paralelo.
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
		/// Mutex para la sincronizaci�n de finalizaci�n.
        std::mutex _endMutex;
		/// Mutex para la sincronizaci�n de finalizaci�n.
        std::mutex _endedMutex;


    };

} // namespace Application
