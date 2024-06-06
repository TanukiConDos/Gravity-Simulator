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

        void run();

    private:
        Window window = Window{ WIDTH, HEIGHT };
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject*>> objects = std::make_shared<std::vector<Engine::Physic::PhysicObject*>>();
        std::unique_ptr<Engine::Graphic::Renderer> renderer;

        Engine::Physic::PhysicSystem physicSystem;
        StateMachine* stateMachine = StateMachine::getStateMachine();
        float frameTime = 0, tickTime = 0;
    };

}

