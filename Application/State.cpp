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
        case Foundation::BRUTE_FORCE:   return "Fuerza bruta";
        case Foundation::OCTREE:   return "Octree";
        }
    }

    inline const char* toString(Foundation::Mode mode)
    {
        switch (mode)
        {
        case Foundation::RANDOM:   return "Aleatorio";
        case Foundation::FILE:   return "JSON";
        }
    }


	void MainMenu::frame()
	{
        ImGui::Begin("MainMenu",0, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImVec2 size = ImGui::GetMainViewport()->Size;
        ImGui::SetWindowPos(ImVec2{ (size[0] / 2) - 300,(size[1] / 2) - 100 });
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
            context->getSub()->initSimulation();
            context->changeState(new Debug(context, new State(context)));
            break;

        case Action::CONFIGURATION:
            context->changeState(new Config(context));
            break;

        default:
            break;
        }
    }

	void Debug::frame()
	{
        state->frame();
        Foundation::Timers* timers = Foundation::Timers::getTimers();
        std::string frameTimeStr = "Frametime: ";
        frameTimeStr += std::to_string(timers->getElapsedTime(Foundation::FRAME));
        frameTimeStr += "ms";
        std::string tickTimeStr = "Ticktime: ";
        tickTimeStr += std::to_string(timers->getElapsedTime(Foundation::TICK));
        tickTimeStr += "ms";

        
        ImGui::Begin("Debug",0, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);
        ImGui::Text(frameTimeStr.c_str());
        ImGui::Text(tickTimeStr.c_str());
        ImGui::End();
	}
    void Debug::changeState(Action action)
    {
        context->changeState(state);
    }
    void Config::frame()
    {
        Foundation::Config* config = Foundation::Config::getConfig();
        ImGui::Begin("Config",0, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar);

        ImGui::InputFloat("Multiplicador paso del tiempo", &config->time);

        if (ImGui::BeginCombo("Modo de creación de la escena", toString(config->systemCreationMode)))
        {
            for (int i = Foundation::RANDOM; i <= Foundation::FILE; i++)
            {
                Foundation::Mode mode = static_cast<Foundation::Mode>(i);
                bool isSelected = mode == config->systemCreationMode;
                if (ImGui::Selectable(toString(mode), isSelected)) config->systemCreationMode = mode;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }
        if (config->systemCreationMode == Foundation::FILE)
        {
            ImGui::InputText("fichero JSON", config->fichero, 100);
        }
        if (config->systemCreationMode == Foundation::RANDOM)
        {
            ImGui::InputInt("Numero de objetos", &config->numObjects,0,0);
        }

        if (ImGui::BeginCombo("Collision Algorithm", toString(config->collisionAlgorithm)))
        {
            for (int i = Foundation::BRUTE_FORCE; i <= Foundation::OCTREE; i++)
            {
                Foundation::Algorithm algorithm = static_cast<Foundation::Algorithm>(i);
                bool isSelected = algorithm == config->collisionAlgorithm;
                if(ImGui::Selectable(toString(algorithm), isSelected)) config->collisionAlgorithm = algorithm;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }

        if (ImGui::BeginCombo("Solver Algorithm", toString(config->SolverAlgorithm)))
        {
            for (int i = Foundation::BRUTE_FORCE; i <= Foundation::OCTREE; i++)
            {
                Foundation::Algorithm algorithm = static_cast<Foundation::Algorithm>(i);
                bool isSelected = algorithm == config->SolverAlgorithm;
                if(ImGui::Selectable(toString(algorithm), isSelected)) config->SolverAlgorithm = algorithm;
                if (isSelected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
        }
        if (ImGui::Button("Guardar")) changeState(Action::SAVE);
        ImGui::End();
    }

    

    void Config::changeState(Action action)
    {
        switch (action)
        {
        case Action::SAVE:
            context->changeState(new MainMenu(context));
            break;
        default:
            break;
        }
    }

    void ObjectSelected::frame()
    {
    }

    void ObjectSelected::changeState(Action action)
    {
    }

    StateMachine* StateMachine::getStateMachine()
    {
        static StateMachine instance;
        instance.state = new MainMenu(&instance);
        return &instance;
    }
    void StateMachine::frame()
    {
        state->frame();
    }
}