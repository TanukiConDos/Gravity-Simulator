#pragma once

#include <iostream>
#include <stdexcept>

#include "Window.h"
#include "../Engine/Graphic/GPU.h"

namespace Application
{
    class GravitySimulator
    {
    public:

        const int WIDTH = 800;
        const int HEIGHT = 600;

        void run();

        

    private:

        Window window = Window{ WIDTH,HEIGHT };
        Engine::Graphic::GPU gpu = Engine::Graphic::GPU{ &window };
    };

}

