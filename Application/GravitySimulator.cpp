#include "GravitySimulator.h"
#include <thread>
namespace Application
{
    GravitySimulator::GravitySimulator()
    {
        for (int i = 0; i < 20; i++)
        {
            switch (i % 6)
            {
            case 0:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{i * 1e8 + 1 * 1e8,i,i },glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
                break;
            case 1:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{i ,i * 1e8 + 1 * 1e8,i },glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
                break;
            case 2:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{i ,i ,i * 1e8 + 1 * 1e8},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
            case 3:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{-i * 1e8 - 1 * 1e8,i,i },glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
                break;
            case 4:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{i ,-i * 1e8 - 1 * 1e8,i },glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
                break;
            case 5:
                objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{i ,i ,-i * 1e8 - 1 * 1e8},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });

            }
        }
        objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,0,0},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 });
        objects.push_back(Engine::Physic::PhysicObject{ glm::dvec3{0,383400e3,0},glm::dvec3{20e3,0,0},glm::dvec3{0,0,0},7.35e25,6737e3 });
        
        renderer = std::make_unique<Engine::Graphic::Renderer>(window, objects,frameTime,tickTime);
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
            auto tick_start = std::chrono::high_resolution_clock::now();
            physicSystem.update(elapsed_time_ms,objects);
            auto tick_end = std::chrono::high_resolution_clock::now();
            auto frame_start = std::chrono::high_resolution_clock::now();
            renderer->drawFrame();
            auto frame_end = std::chrono::high_resolution_clock::now();
            auto t_end = std::chrono::high_resolution_clock::now();
            elapsed_time_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();
            acc += elapsed_time_ms;
            if (acc > 500)
            {
                acc = 0;
                tickTime = std::chrono::duration<double, std::milli>(tick_end - tick_start).count();
                frameTime = std::chrono::duration<double, std::milli>(frame_end - frame_start).count();
            }
        }

        renderer->wait();
    }
    
}