#include "pch.h"
#include "../Engine/Physic/PhysicObject.h"
#include <cmath>

TEST(PhysicObjectTest, UpdateFunction) {

    glm::vec3 initialPosition(0.0f, 0.0f, 0.0f);
    glm::vec3 initialVelocity(0.0f, 0.0f, 0.0f);
    float mass = 1.0f;
    float radius = 1.0f;
    Engine::Physic::PhysicObject object(initialPosition, initialVelocity, mass, radius);

    glm::vec3 force(10.0f, 0.0f, 0.0f);
    float deltaTime = 1.0f;


    object.update(deltaTime, force);


    glm::vec3 expectedPosition(5.0f, 0.0f, 0.0f);
    glm::vec3 expectedVelocity(10.0f, 0.0f, 0.0f);

    EXPECT_NEAR(object._position.x, expectedPosition.x, 0.001f);
    EXPECT_NEAR(object._position.y, expectedPosition.y, 0.001f);
    EXPECT_NEAR(object._position.z, expectedPosition.z, 0.001f);

    EXPECT_NEAR(object._velocity.x, expectedVelocity.x, 0.001f);
    EXPECT_NEAR(object._velocity.y, expectedVelocity.y, 0.001f);
    EXPECT_NEAR(object._velocity.z, expectedVelocity.z, 0.001f);
}

TEST(PhysicObjectTest, CollisionFunction) {

    glm::vec3 position1(0.0f, 0.0f, 0.0f);
    glm::vec3 velocity1(1.0f, 0.0f, 0.0f);
    float mass1 = 2.0f;
    float radius1 = 1.0f;

    glm::vec3 position2(1.5f, 0.0f, 0.0f);
    glm::vec3 velocity2(-1.0f, 0.0f, 0.0f);
    float mass2 = 2.0f;
    float radius2 = 1.0f;

    Engine::Physic::PhysicObject object1(position1, velocity1, mass1, radius1);
    Engine::Physic::PhysicObject object2(position2, velocity2, mass2, radius2);


    object1.collision(object2);


    glm::vec3 expectedPosition1(-0.5f, 0.0f, 0.0f);
    glm::vec3 expectedPosition2(1.5f, 0.0f, 0.0f);

    glm::vec3 expectedVelocity1(-1.0f, 0.0f, 0.0f);
    glm::vec3 expectedVelocity2(1.0f, 0.0f, 0.0f);

    EXPECT_NEAR(object1._position.x, expectedPosition1.x, 0.001f);
    EXPECT_NEAR(object1._position.y, expectedPosition1.y, 0.001f);
    EXPECT_NEAR(object1._position.z, expectedPosition1.z, 0.001f);

    EXPECT_NEAR(object2._position.x, expectedPosition2.x, 0.001f);
    EXPECT_NEAR(object2._position.y, expectedPosition2.y, 0.001f);
    EXPECT_NEAR(object2._position.z, expectedPosition2.z, 0.001f);

    EXPECT_NEAR(object1._velocity.x, expectedVelocity1.x, 0.001f);
    EXPECT_NEAR(object1._velocity.y, expectedVelocity1.y, 0.001f);
    EXPECT_NEAR(object1._velocity.z, expectedVelocity1.z, 0.001f);

    EXPECT_NEAR(object2._velocity.x, expectedVelocity2.x, 0.001f);
    EXPECT_NEAR(object2._velocity.y, expectedVelocity2.y, 0.001f);
    EXPECT_NEAR(object2._velocity.z, expectedVelocity2.z, 0.001f);
}

TEST(PhysicObjectTest, Constructor) {

    glm::vec3 expectedPosition(1.0f, 2.0f, 3.0f);
    glm::vec3 expectedVelocity(4.0f, 5.0f, 6.0f);
    float expectedMass = 10.0f;
    float expectedRadius = 2.0f;


    Engine::Physic::PhysicObject object(expectedPosition, expectedVelocity, expectedMass, expectedRadius);


    EXPECT_NEAR(object._position.x, expectedPosition.x, 0.001f);
    EXPECT_NEAR(object._position.y, expectedPosition.y, 0.001f);
    EXPECT_NEAR(object._position.z, expectedPosition.z, 0.001f);

    EXPECT_NEAR(object._velocity.x, expectedVelocity.x, 0.001f);
    EXPECT_NEAR(object._velocity.y, expectedVelocity.y, 0.001f);
    EXPECT_NEAR(object._velocity.z, expectedVelocity.z, 0.001f);

    EXPECT_NEAR(object._mass, expectedMass, 0.001f);
    EXPECT_NEAR(object._radius, expectedRadius, 0.001f);
}