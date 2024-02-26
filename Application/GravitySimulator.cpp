#include "GravitySimulator.h"
#include <thread>
namespace Application
{
    GravitySimulator::GravitySimulator()
    {
        objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,0,0},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
        objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,383400e3,0},glm::dvec3{9.91e3,0,0},glm::dvec3{0,0,0},7.35e25,6737e3 });
        
        renderer = std::make_unique<Engine::Graphic::Renderer>(window, objects);
        std::unique_ptr<Engine::Physic::BroadCollisionDetectionInterface> broadalgorithm = std::make_unique<Engine::Physic::BroadCollisionDetectionInterface>();
        std::unique_ptr<Engine::Physic::NarrowCollisionDetectionInterface> narrowAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
        std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();

        physicSystem = Engine::Physic::PhysicSystem{ std::move(broadalgorithm), std::move(narrowAlgorithm), std::move(solverAlgorithm)};
    }
    void GravitySimulator::run()
    {
        double elapsed_time_ms = 0;
        while (!glfwWindowShouldClose(window.getWindow())) {

            auto t_start = std::chrono::high_resolution_clock::now();
            glfwPollEvents();
            physicSystem.update(elapsed_time_ms,objects);
            renderer->drawFrame();
            auto t_end = std::chrono::high_resolution_clock::now();
            elapsed_time_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();
        }

        renderer->wait();
    }
    
}