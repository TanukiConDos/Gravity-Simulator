#include "GravitySimulator.h"


namespace Application
{
    GravitySimulator::GravitySimulator()
    {
        window = std::make_shared<Window>(WIDTH, HEIGHT);
        
        objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();
        objects->push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,0,0},glm::dvec3{0,0,0},glm::dvec3{0,0,0},20,20000 });
        objects->push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,2e6,0},glm::dvec3{0,0,0},glm::dvec3{0,0,0},2e27,1 });
        gpu = std::make_unique<Engine::Graphic::GPU>(window, objects, 2);

        std::unique_ptr<Engine::Physic::BroadCollisionDetectionInterface> broadDetectionAlgorithm = std::make_unique<Engine::Physic::BroadCollisionDetectionInterface>();
        std::unique_ptr<Engine::Physic::bruteForceDetection> narrowDetectionAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
        std::unique_ptr<Engine::Physic::BruteForceSolver> solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();
        physicSystem = std::make_unique<Engine::Physic::PhysicSystem>(std::move(broadDetectionAlgorithm),std::move(narrowDetectionAlgorithm),std::move(solverAlgorithm),objects,2);
    }
    void GravitySimulator::run()
    {
        double elapsed_time_ms = 0;
        while (!glfwWindowShouldClose(window->getWindow())) {

            auto t_start = std::chrono::high_resolution_clock::now();
            glfwPollEvents();
            physicSystem->update(elapsed_time_ms,objects,2);
            gpu->drawFrame();
            auto t_end = std::chrono::high_resolution_clock::now();
            elapsed_time_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();
        }

        gpu->wait();
    }
    
}