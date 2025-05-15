#include "pch.h"
#include "../Engine/Physic/OctTree.h"
#include "../Engine/Physic/PhysicSystem.h"
#include "../Engine/Physic/PhysicObject.h"
#include <glm/vec3.hpp>
#include <gtest/gtest.h>
#include <memory>
#include <vector>
#include <cmath>


TEST(OctTreeTest, NoCollisions) {
    auto objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();

    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(-100.0f, 0.0f, 0.0f),
                                                    glm::vec3(0.0f),
                                                    1.0f,
                                                    1.0f));
    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(100.0f, 0.0f, 0.0f),
                                                    glm::vec3(0.0f),
                                                    1.0f,
                                                    1.0f));

    Engine::Physic::OctTree tree(objects);

    auto collisions0 = tree.checkCollisions(0);
    auto collisions1 = tree.checkCollisions(1);
    EXPECT_TRUE(collisions0.size() == 1);
    EXPECT_TRUE(collisions1.size() == 1);
}

TEST(OctTreeTest, CollisionDetection) {
    auto objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();

    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(0.0f, 0.0f, 0.0f),
                                                    glm::vec3(0.0f),
                                                    1.0f,
                                                    2.0f));
    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(1.0f, 0.0f, 0.0f),
                                                    glm::vec3(0.0f),
                                                    1.0f,
                                                    2.0f));

    Engine::Physic::OctTree tree(objects);
    tree.massCalculation();

    auto collisions0 = tree.checkCollisions(0);
    auto collisions1 = tree.checkCollisions(1);
    EXPECT_FALSE(collisions0.empty());
    EXPECT_FALSE(collisions1.empty());
    

    bool found0 = false;
    for (int id : collisions0) {
        if (id == 1) { found0 = true; break; }
    }
    bool found1 = false;
    for (int id : collisions1) {
        if (id == 0) { found1 = true; break; }
    }
    EXPECT_TRUE(found0);
    EXPECT_TRUE(found1);
}


TEST(OctTreeTest, BarnesHutComputation) {
    auto objects = std::make_shared<std::vector<Engine::Physic::PhysicObject>>();

    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(0.0f, 0.0f, 0.0f),
                                                    glm::vec3(0.0f),
                                                    2.0f,
                                                    1.0f));
    objects->push_back(Engine::Physic::PhysicObject(glm::vec3(5.0f, 5.0f, 5.0f),
                                                    glm::vec3(0.0f),
                                                    3.0f,
                                                    1.0f));

    Engine::Physic::OctTree tree(objects);
    tree.massCalculation();

    glm::vec3 force = tree.barnesHut(0);
    EXPECT_TRUE(std::isfinite(force.x));
    EXPECT_TRUE(std::isfinite(force.y));
    EXPECT_TRUE(std::isfinite(force.z));
}

