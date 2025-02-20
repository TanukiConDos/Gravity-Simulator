/**
 * @file main.cpp
 * @brief Punto de entrada de la aplicación.
 *
 * Se crea una instancia de GravitySimulator y se ejecuta utilizando app.run().
 * Se utiliza un bloque try/catch para capturar excepciones derivadas de std::exception y reportar errores.
 */

#include "Application/GravitySimulator.h"
#include <iostream>

int main()
{
    Application::GravitySimulator app{};

    try {
        app.run();
    }
    catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }

    return 0;
}