#pragma once

#include <iostream>
#include <stdexcept>

#include "Window.h"
#include "../Engine/Graphic/GPU.h"
#include "../Engine/Graphic/Renderer.h"
#include "../Engine/Physic/PhysicSystem.h"
#include "../Engine/Physic/bruteForceDetection.h"
#include "../Engine/Physic/BruteForceSolver.h"

namespace Application
{
    class GravitySimulator
    {
    public:

        const int WIDTH = 1920;
        const int HEIGHT = 1080;

        GravitySimulator();

        void run();

    private:

        Window window = Window{ WIDTH, HEIGHT };
        std::vector<Engine::Physic::PhysicObject> objects;
        std::unique_ptr<Engine::Graphic::Renderer> renderer;

        Engine::Physic::PhysicSystem physicSystem;
    };

}

