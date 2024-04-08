#include "GravitySimulator.h"
#include "../Engine/Physic/OctTreeSolver.h"

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
        std::uniform_real_distribution distrib(0.0f, 1.0f);
        for (int i = 0; i < 1000; i++)
        {
            float x = distrib(gen) * 2e11f - 1e11f;
            float y = distrib(gen) * 2e11f - 1e11f;
            float z = distrib(gen) * 2e11f - 1e11f;
            objects->push_back(Engine::Physic::PhysicObject::physicObject(glm::vec3{x,y,z},glm::vec3{0,0,0},glm::vec3{0,0,0},6e27f,12371e3f ));
        }
        objects->push_back(Engine::Physic::PhysicObject::physicObject( glm::vec3{0,0,0},glm::vec3{0,0,0},glm::vec3{0,0,0},6e27f,12371e3f ));
        objects->push_back(Engine::Physic::PhysicObject::physicObject( glm::vec3{0,383400e3f,0},glm::vec3{20e3f,0,0},glm::vec3{0,0,0},7.35e25f,6737e3f ));
        
        renderer = std::make_unique<Engine::Graphic::Renderer>(window, objects, frameTime, tickTime);
        //Engine::Physic::OctTree* tree = new Engine::Physic::OctTree(objects);
        //std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm = std::make_unique<Engine::Physic::OctTreeCollisionDetection>(*tree);
        //std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm = std::make_unique<Engine::Physic::OctTreeSolver>(*tree,200.0);

        std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
        std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();
        

        physicSystem = Engine::Physic::PhysicSystem{ std::move(collisionAlgorithm), std::move(solverAlgorithm)};
    }
    void GravitySimulator::run()
    {
        float elapsed_time_ms = 0;
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
            elapsed_time_ms = std::chrono::duration<float, std::milli>(t_end - t_start).count();
            acc += elapsed_time_ms;
            if (acc > 100)
            {
                acc = 0;
                tickTime = std::chrono::duration<float, std::milli>(tick_end - tick_start).count();
                frameTime = std::chrono::duration<float, std::milli>(frame_end - frame_start).count();
            }
        }

        renderer->wait();
    }
    
}