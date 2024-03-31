#include "GravitySimulator.h"

namespace Application
{
    GravitySimulator::GravitySimulator()
    {
        std::random_device rd;
        std::mt19937::result_type seed = rd() ^ (
            (std::mt19937::result_type)
            std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()
            ).count() +
            (std::mt19937::result_type)
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::high_resolution_clock::now().time_since_epoch()
            ).count());
        std::mt19937 gen(seed);
        std::uniform_real_distribution distrib(0.0, 1.0);
        for (int i = 0; i < 1000; i++)
        {
            double x = distrib(gen) * 2e10 - 1e10;
            double y = distrib(gen) * 2e10 - 1e10;
            double z = distrib(gen) * 2e10 - 1e10;
            objects->push_back(Engine::Physic::PhysicObject::physicObject(glm::dvec3{x,y,z},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 ));
        }
        objects->push_back(Engine::Physic::PhysicObject::physicObject( glm::dvec3{0,0,0},glm::dvec3{0,0,0},glm::dvec3{0,0,0},6e27,12371e3 ));
        objects->push_back(Engine::Physic::PhysicObject::physicObject( glm::dvec3{0,383400e3,0},glm::dvec3{20e3,0,0},glm::dvec3{0,0,0},7.35e25,6737e3 ));
        
        renderer = std::make_unique<Engine::Graphic::Renderer>(window, objects, frameTime, tickTime);
        std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm = std::make_unique<Engine::Physic::OctTreeCollisionDetection>(objects);
        //std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
        std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();

        physicSystem = Engine::Physic::PhysicSystem{ std::move(collisionAlgorithm), std::move(solverAlgorithm)};
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
            if (acc > 100)
            {
                acc = 0;
                tickTime = std::chrono::duration<double, std::milli>(tick_end - tick_start).count();
                frameTime = std::chrono::duration<double, std::milli>(frame_end - frame_start).count();
            }
        }

        renderer->wait();
    }
    
}