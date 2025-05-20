#include "State.h"
#include "../Engine/Graphic/imGUIWindow.h"
#include "GravitySimulator.h"
#include "../Foundation/Timers.h"
#include "../Foundation/Config.h"
namespace Application
{
    inline const char* toString(Foundation::Algorithm algorithm)
    {
        switch (algorithm)
        {
        case Foundation::Algorithm::BRUTE_FORCE:   return "Fuerza bruta";
        case Foundation::Algorithm::OCTREE:   return "Octree";
        }
    }

    inline const char* toString(Foundation::Mode mode)
    {
        switch (mode)
        {
        case Foundation::Mode::RANDOM:   return "Aleatorio";
        case Foundation::Mode::FILE:   return "JSON";
        }
    }


	void MainMenu::frame()
	{
        ImGui::Begin("MainMenu",nullptr, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImVec2 size = ImGui::GetMainViewport()->Size;
        ImVec2 windowSize = ImGui::GetWindowSize();
        ImGui::SetWindowPos(ImVec2{ (size[0] / 2) - (windowSize[0] / 2),(size[1] / 2) - (windowSize[1] / 2) });
        ImGui::SetWindowSize("MainMenu", ImVec2{300,100});
        ImGui::Text("SIMULADOR DE FUERZA GRAVITATORIA");
        if (ImGui::Button("Iniciar Simulacion")) changeState(Action::BEGIN_SIMULATION);
        if (ImGui::Button("Configuracion")) changeState(Action::CONFIGURATION);

        ImGui::End();
	}

    void MainMenu::changeState(Action action)
    {
        switch (action)
        {
        case Action::BEGIN_SIMULATION:
        {
            _context->_sub->initSimulation();
            std::unique_ptr<State> state = std::make_unique<State>(_context);
            std::unique_ptr <State> debug = std::make_unique<Debug>(_context, std::move(state));
            std::unique_ptr<State> objectSelected = std::make_unique<ObjectSelected>(_context, std::move(debug));
            
            _context->changeState(std::move(objectSelected));
        }
           
            break;

        case Action::CONFIGURATION:
        {
            std::unique_ptr<State> config = std::make_unique<Config>(_context);
            _context->changeState(std::move(config));
        }
            break;

        default:
            break;
        }
    }

	void Debug::frame()
	{
        std::string frameTimeStr = "Frametime: ";
        frameTimeStr += std::to_string(*_context->_frameTime);
        frameTimeStr += "ms";
        std::string tickTimeStr = "Ticktime: ";
        tickTimeStr += std::to_string(*_context->_tickTime);
        tickTimeStr += "ms";

        
        ImGui::Begin("Debug",nullptr, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImGui::Text("%s",frameTimeStr.c_str());
        ImGui::Text("%s",tickTimeStr.c_str());
        ImGui::End();
	}
    void Debug::changeState(Action action)
    {
        _context->changeState(std::move(_state));
    }
    void Config::frame()
    {
        Foundation::Config* config = Foundation::Config::getConfig();
        ImGui::Begin("Config",nullptr, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImVec2 size = ImGui::GetMainViewport()->Size;
        ImVec2 windowSize = ImGui::GetWindowSize();
        ImGui::SetWindowPos(ImVec2{ (size[0] / 2) - (windowSize[0] / 2),(size[1] / 2) - (windowSize[1] / 2) });
        ImGui::InputFloat("Multiplicador paso del tiempo", &config->_time);

        if (ImGui::BeginCombo("Modo de creacion de la escena", toString(config->_systemCreationMode)))
        {
            for (int i = 0; i <= 1; i++)
            {
                Foundation::Mode mode = static_cast<Foundation::Mode>(i);
                bool isSelected = mode == config->_systemCreationMode;
                if (ImGui::Selectable(toString(mode), isSelected)) config->_systemCreationMode = mode;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }
        if (config->_systemCreationMode == Foundation::Mode::FILE)
        {
     
            ImGui::InputText("Fichero JSON", config->_fichero, 100);
        }
        if (config->_systemCreationMode == Foundation::Mode::RANDOM)
        {
            ImGui::InputInt("Numero de objetos", &config->_numObjects,0,0);
        }

        if (ImGui::BeginCombo("Algoritmo de deteccion de colision", toString(config->_collisionAlgorithm)))
        {
            for (int i = 0; i <= 1; i++)
            {
                Foundation::Algorithm algorithm = static_cast<Foundation::Algorithm>(i);
                bool isSelected = algorithm == config->_collisionAlgorithm;
                if(ImGui::Selectable(toString(algorithm), isSelected)) config->_collisionAlgorithm = algorithm;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }

        if (ImGui::BeginCombo("Algoritmo de resolucion", toString(config->_SolverAlgorithm)))
        {
            for (int i = 0; i <= 1; i++)
            {
                Foundation::Algorithm algorithm = static_cast<Foundation::Algorithm>(i);
                bool isSelected = algorithm == config->_SolverAlgorithm;
                if(ImGui::Selectable(toString(algorithm), isSelected)) config->_SolverAlgorithm = algorithm;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }
        if (ImGui::Button("Guardar")) changeState(Action::SAVE);
        ImGui::End();
    }

    

    void Config::changeState(Action action)
    {
        if (action == Action::SAVE)
        {
            std::unique_ptr<State> mainMenu = std::make_unique<MainMenu>(_context);
            _context->changeState(std::move(mainMenu));
        }
    }

    ObjectSelected::ObjectSelected(std::shared_ptr<StateMachine> context, std::unique_ptr<State> state) : State(context), _state(std::move(state))
    {
        _pos[0] = &context->_objects->at(_objectId)._position[0];
        _pos[1] = &context->_objects->at(_objectId)._position[1];
        _pos[2] = &context->_objects->at(_objectId)._position[2];
        _vel[0] = &context->_objects->at(_objectId)._velocity[0];
        _vel[1] = &context->_objects->at(_objectId)._velocity[1];
        _vel[2] = &context->_objects->at(_objectId)._velocity[2];
        _acc[0] = &context->_objects->at(_objectId)._acceleration[0];
        _acc[1] = &context->_objects->at(_objectId)._acceleration[1];
        _acc[2] = &context->_objects->at(_objectId)._acceleration[2];
        _mass = &context->_objects->at(_objectId)._mass;
        _radius = &context->_objects->at(_objectId)._radius;
        context->_objects->at(_objectId)._selected = true;
    }

    void ObjectSelected::frame()
    {
        _state->frame();
        if (_oldId != _objectId && _objectId < _context->_objects->size() && _objectId > -1)
        {
            _pos[0] = &_context->_objects->at(_objectId)._position[0];
            _pos[1] = &_context->_objects->at(_objectId)._position[1];
            _pos[2] = &_context->_objects->at(_objectId)._position[2];
            _vel[0] = &_context->_objects->at(_objectId)._velocity[0];
            _vel[1] = &_context->_objects->at(_objectId)._velocity[1];
            _vel[2] = &_context->_objects->at(_objectId)._velocity[2];
            _acc[0] = &_context->_objects->at(_objectId)._acceleration[0];
            _acc[1] = &_context->_objects->at(_objectId)._acceleration[1];
            _acc[2] = &_context->_objects->at(_objectId)._acceleration[2];
            _mass = &_context->_objects->at(_objectId)._mass;
            _radius = &_context->_objects->at(_objectId)._radius;
            _context->_objects->at(_objectId)._selected = true;
            if(_oldId != -1) _context->_objects->at(_oldId)._selected = false;
            _oldId = _objectId;
        }
        else
        {
			_objectId = _oldId;
        }
        
        ImGui::Begin("ItemSelected", nullptr, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImVec2 size = ImGui::GetMainViewport()->Size;
        ImVec2 windowSize = ImGui::GetWindowSize();
        ImGui::SetWindowPos(ImVec2{ size[0] - windowSize[0],0});

        ImGui::InputInt("Id",&_objectId);

        std::array<float,3> posAux;
        for (int i = 0; i < 3; i++)
        {
            posAux[i] = *_pos[i] / 1000;
        }
        double massAux = *_mass / 1000;
        float radiusAux = *_radius / 1000;

        if (ImGui::InputFloat3("posicion", posAux.data(), "%.0f %km"), ImGuiInputTextFlags_EnterReturnsTrue) *_pos.data() = posAux.data();
        ImGui::InputFloat3("velocidad", *_vel.data(), "%.2f %m/s", ImGuiInputTextFlags_EnterReturnsTrue);
        ImGui::InputFloat3("acceleracion", *_acc.data(), "%.2f %m/s^2", ImGuiInputTextFlags_EnterReturnsTrue);

        if(ImGui::InputDouble("masa", &massAux, 0.0, 0.0, "%.3e %kg", ImGuiInputTextFlags_EnterReturnsTrue) && massAux > 0) *_mass = massAux;
        if(ImGui::InputFloat("radio", &radiusAux, 0.0, 0.0, "%.0f %km", ImGuiInputTextFlags_EnterReturnsTrue)) *_radius = radiusAux;

        if (ImGui::Button("finalizar simulacion")) changeState(Action::EXIT);

        ImGui::End();
        
    }

    void ObjectSelected::changeState(Action action)
    {
        if (action == Action::EXIT)
        {
            _context->_sub->endSimulation();
            std::unique_ptr<State> mainMenu = std::make_unique<MainMenu>(_context);
            _context->changeState(std::move(mainMenu));
        }
    }

    std::shared_ptr<StateMachine> StateMachine::getStateMachine()
    {
        if (g_stateMachine == nullptr)
        {
            g_stateMachine = std::make_shared<StateMachine>();
        }
        g_stateMachine->_state = std::make_unique<MainMenu>(g_stateMachine);
        return g_stateMachine;
    }
    void StateMachine::frame()
    {
        _state->frame();
    }
}