#pragma once

#include <iostream>
#include <stdexcept>
#include <thread>
#include <random>

#include "Window.h"
#include "../Engine/Graphic/Renderer.h"
#include "../Engine/Physic/PhysicSystem.h"


namespace Application
{
    class GravitySimulator
    {
    public:

        const int WIDTH = 1280;
        const int HEIGHT = 720;

        GravitySimulator();

        void initSimulation();
        void endSimulation();
        void run();

    private:
        Window _window = Window{ WIDTH, HEIGHT };
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> _objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();
        std::unique_ptr<Engine::Graphic::Renderer> _renderer;

        Engine::Physic::PhysicSystem _physicSystem;
        std::shared_ptr<StateMachine> _stateMachine = StateMachine::getStateMachine();
        float _frameTime = 0;
        float _tickTime = 0;
    };

}

