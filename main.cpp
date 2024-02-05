#include"Application/GravitySimulator.h"

int main() {

    /*Engine::Physic::PhysicObject object = Engine::Physic::PhysicObject{ glm::dvec3{3,1,0}, glm::dvec3{},glm::dvec3{}, 1, 3 };
    Engine::Physic::PhysicObject object2 = Engine::Physic::PhysicObject{ glm::dvec3{2,-1,5}, glm::dvec3{},glm::dvec3{}, 1, 3 };

    object.collision(object2);*/

    Application::GravitySimulator app{};

    try {
        app.run();
    }
    catch (const std::exception& e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }

    return 0;
}
