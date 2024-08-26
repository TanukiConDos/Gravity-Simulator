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
        
        _renderer = std::make_unique<Engine::Graphic::Renderer>(_window, _objects, &_frameTime, &_tickTime);
        _stateMachine->_sub = this;
        _window.attachCameraToEvent(_renderer->getCamera());
    }

    void GravitySimulator::initSimulation()
    {
        auto config = Foundation::Config::getConfig();
        switch (config->systemCreationMode)
        {
        case Foundation::Mode::RANDOM:
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

            _objects->emplace_back(glm::vec3{ 0,0,0 }, glm::vec3{ 0,0,0 }, 6e27f, 12371e3f);
            _objects->emplace_back(glm::vec3{ 0,383400e3f,0 }, glm::vec3{ 20e3f,0,0 }, 7.35e25f, 6737e3f);
            for (int i = 0; i < config->numObjects; i++)
            {
                float x = distrib(gen) * 2e10f - 1e10f;
                float y = distrib(gen) * 2e10f - 1e10f;
                float z = distrib(gen) * 2e10f - 1e10f;
                _objects->emplace_back(glm::vec3{ x,y,z }, glm::vec3{ 0,0,0 }, 6e27f, 12371e3f);
                j.emplace_back(_objects->back());
            }
            
            std::string data = j.dump();
            Foundation::File file = Foundation::File{ "./scenes/last.json", false};
            file.write(data);
            break;
        }
        case Foundation::Mode::FILE:
        {

            Foundation::File file = Foundation::File(std::string("./scenes/").append(config->fichero));
            std::vector<char> aux = file.read();
            std::string data = std::string{ aux.data()};
            data.erase(aux.size());
            nlohmann::json j = nlohmann::json::parse(data);
            for (auto object : j)
            {
                Engine::Physic::PhysicObject obj = Engine::Physic::PhysicObject(glm::vec3{ 0,0,0 }, glm::vec3{ 0,0,0 }, 0.0f, 0.0f);
                Engine::Physic::from_json(object, obj);
                _objects->emplace_back(obj);
            }
            break;
        }
        }
        _stateMachine->_objects = _objects;
        std::unique_ptr<Engine::Physic::CollisionDetectionInterface> collisionAlgorithm;
        std::shared_ptr<Engine::Physic::OctTree> tree = nullptr;
        switch(config->collisionAlgorithm)
        {
        case Foundation::Algorithm::BRUTE_FORCE:
            collisionAlgorithm = std::make_unique<Engine::Physic::bruteForceDetection>();
            break;
        case Foundation::Algorithm::OCTREE:
            tree = std::make_shared<Engine::Physic::OctTree>(_objects);
            collisionAlgorithm = std::make_unique<Engine::Physic::OctTreeCollisionDetection>(tree);
            break;
        }


        std::unique_ptr<Engine::Physic::SolverInterface> solverAlgorithm;
        switch (config->collisionAlgorithm)
        {
        case Foundation::Algorithm::BRUTE_FORCE:
            solverAlgorithm = std::make_unique<Engine::Physic::BruteForceSolver>();
            break;
        case Foundation::Algorithm::OCTREE:
            if(tree == nullptr) tree = std::make_shared<Engine::Physic::OctTree>(_objects);
            solverAlgorithm = std::make_unique<Engine::Physic::OctTreeSolver>(tree);
            break;
        }


        _physicSystem = Engine::Physic::PhysicSystem{ std::move(collisionAlgorithm), std::move(solverAlgorithm) };
        _renderer->updateObjects();
    }

    void GravitySimulator::endSimulation()
    {
        _objects->clear();
        _renderer->updateObjects();
    }


    void GravitySimulator::run()
    {
        
        Foundation::Timers* timers = Foundation::Timers::getTimers();
        float elapsed_time_ms = 0;
        while (!glfwWindowShouldClose(_window.getWindow())) {
            glfwPollEvents();
            timers->setTimer(Foundation::Timer::TICK, true);
            _physicSystem.update(elapsed_time_ms,_objects);
            timers->setTimer(Foundation::Timer::TICK, false);

            timers->setTimer(Foundation::Timer::FRAME, true);
            _renderer->drawFrame();
            timers->setTimer(Foundation::Timer::FRAME, false);

            _frameTime = timers->getElapsedTime(Foundation::Timer::FRAME);
            _tickTime = timers->getElapsedTime(Foundation::Timer::TICK);
            elapsed_time_ms = _frameTime + _tickTime;
        }

        _renderer->wait();
    }
    
}