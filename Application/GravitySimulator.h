#pragma once

#include <iostream>
#include <stdexcept>

#include "Window.h"
#include "../Engine/Graphic/GPU.h"
#include "../Engine/Physic/PhysicSystem.h"
#include "../Engine/Physic/bruteForceDetection.h"
#include "../Engine/Physic/BruteForceSolver.h"

namespace Application
{
    class GravitySimulator
    {
    public:

        const int WIDTH = 800;
        const int HEIGHT = 600;

        GravitySimulator();

        void run();

    private:

        std::shared_ptr<Window> window;
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject>> objects;
        std::unique_ptr<Engine::Graphic::GPU> gpu;

        std::unique_ptr < Engine::Physic::PhysicSystem> physicSystem;
    };

}

