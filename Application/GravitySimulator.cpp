#include "GravitySimulator.h"


namespace Application
{
    void GravitySimulator::run()
    {
        while (!glfwWindowShouldClose(window.getWindow())) {
            glfwPollEvents();
            gpu.drawFrame();
        }

        gpu.wait();
    }
    
}