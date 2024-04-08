#pragma once

#include <iostream>
#include <stdexcept>
#include <thread>
#include <random>

#include "Window.h"
#include "../Engine/Graphic/GPU.h"
#include "../Engine/Graphic/Renderer.h"
#include "../Engine/Physic/PhysicSystem.h"
#include "../Engine/Physic/bruteForceDetection.h"
#include "../Engine/Physic/BruteForceSolver.h"
#include "../Engine/Physic/OctTreeCollisionDetection.h"
#include "../Engine/Physic/OctTree.h"


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
        std::shared_ptr<std::vector<Engine::Physic::PhysicObject*>> objects = std::make_shared<std::vector<Engine::Physic::PhysicObject*>>();
        std::unique_ptr<Engine::Graphic::Renderer> renderer;

        Engine::Physic::PhysicSystem physicSystem;
        float frameTime = 0, tickTime = 0,acc=0;
    };

}

