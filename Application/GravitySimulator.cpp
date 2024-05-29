#include "GravitySimulator.h"
#include "../Engine/Physic/OctTreeSolver.h"
#include "../Foundation/Config.h"
#include "../Foundation/Timers.h"
#include "../Engine/Physic/bruteForceDetection.h"
#include "../Engine/Physic/BruteForceSolver.h"
#include "../Engine/Physic/OctTreeCollisionDetection.h"
#include "../Engine/Physic/OctTree.h"

namespace Application
{
    GravitySimulator::GravitySimulator()
    {
        
        renderer = std::make_unique<Engine::Graphic::Renderer>(window, objects, frameTime, tickTime);
        stateMachine->sub = this;
        window.attachCameraToEvent(renderer->getCamera());
    }

    void GravitySimulator::initSimulation()
    {
        auto config = Foundation::Config::getConfig();
        switch (config->systemCreationMode)
        {
        case Foundation::RANDOM:
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
            nlohmann::json j = nlohmann::json{ };
            for (int i = 0; i < config->numObjects; i++)
            {
                float x = distrib(gen) * 2e11f - 1e11f;
                float y = distrib(gen) * 2e11f - 1e11f;
                float z = distrib(gen) * 2e11f - 1e11f;
                objects->emplace_back(new Engine::Physic::PhysicObject(glm::vec3{ x,y,z }, glm::vec3{ 0,0,0 }, 6e27f, 12371e3f));
                j.emplace_back(*objects->back());
            }
            objects->emplace_back(new Engine::Physic::PhysicObject(glm::vec3{ 0,0,0 }, glm::vec3{ 0,0,0 }, 6e27f, 12371e3f));
            objects->emplace_back(new Engine::Physic::PhysicObject(glm::vec3{ 0,383400e3f,0 }, glm::vec3{ 20e3f,0,0 }, 7.35e25f, 6737e3f));
            std::string data = j.dump();
            Foundation::File file = Foundation::File{ "./scenes/last.json", false};
            file.write(data);
            break;
        }
        case Foundation::FILE:
        {

            Foundation::File file = Foundation::File(std::string("./scenes/").append(config->fichero));
            std::vector<char> aux = file.read();
            std::string data = std::string{ aux.data()};
            data.erase(aux.size());
            nlohmann::json j = nlohmann::json::parse(data);
            for (auto object : j)
            {
                Engine::Physic::PhysicObject* aux = new Engine::Physic::PhysicObject(glm::vec3{ 0,0,0 }, glm::vec3{ 0,0,0 }, 0.0f, 0.0f);
                Engine::Physic::from_json(object, *aux);
                objects->emplace_back(aux);
            }
            break;
        }
        }
        stateMachine->objects = objects;
        std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm;
        Engine::Physic::OctTree* tree = nullptr;
        switch(config->collisionAlgorithm)
        {
        case Foundation::BRUTE_FORCE:
            collisionAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
            break;
        case Foundation::OCTREE:
            tree = new Engine::Physic::OctTree(objects);
            collisionAlgorithm = std::make_unique<Engine::Physic::OctTreeCollisionDetection>(*tree);
            break;
        }


        std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm;
        switch (config->collisionAlgorithm)
        {
        case Foundation::BRUTE_FORCE:
            solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();
            break;
        case Foundation::OCTREE:
            if(tree == nullptr) tree = new Engine::Physic::OctTree(objects);
            solverAlgorithm = std::make_unique<Engine::Physic::OctTreeSolver>(*tree, 200.0);
            break;
        }


        physicSystem = Engine::Physic::PhysicSystem{ std::move(collisionAlgorithm), std::move(solverAlgorithm) };
        renderer->updateObjects();
    }


    void GravitySimulator::run()
    {
        Foundation::Timers* timers = Foundation::Timers::getTimers();
        float elapsed_time_ms = 0;
        while (!glfwWindowShouldClose(window.getWindow())) {
            glfwPollEvents();
            timers->setTimer(Foundation::TICK, true);
            physicSystem.update(elapsed_time_ms,objects);
            timers->setTimer(Foundation::TICK, false);
            timers->setTimer(Foundation::FRAME, true);
            renderer->drawFrame();
            timers->setTimer(Foundation::FRAME, false);

            elapsed_time_ms = timers->getElapsedTime(Foundation::TICK) + timers->getElapsedTime(Foundation::FRAME);
        }

        renderer->wait();
    }
    
}