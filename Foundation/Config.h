/**
 * @file Config.h
 * @brief Gestiona la configuración de la aplicación, permitiendo obtener parámetros como el modo de creación del sistema,
 * el número de objetos, el tiempo de simulación, el archivo de datos y los algoritmos para colisiones y resolución.
 */

#pragma once
#include <map>
#include <string>

namespace Foundation
{
	/**
	 * @enum Algorithm
	 * @brief Enumera los algoritmos disponibles para la detección de colisiones y resolución de fuerzas.
	 *
	 * - BRUTE_FORCE: Utiliza fuerza bruta para calcular interacciones (verifica cada pareja de objetos).
	 * - OCTREE: Utiliza un árbol octal para optimizar los cálculos reduciendo la complejidad.
	 */
	enum class Algorithm
	{
		BRUTE_FORCE = 0,
		OCTREE = 1
	};
	
	/**
	 * @enum Mode
	 * @brief Define el modo de creación de sistemas para la simulación.
	 *
	 * - RANDOM: Los objetos se generan de forma aleatoria.
	 * - FILE: Los objetos se cargan desde un archivo.
	 */
	enum class Mode
	{
		RANDOM = 0,
		FILE = 1
	};

	/**
	 * @class Config
	 * @brief Clase que maneja la configuración global de la aplicación.
	 *
	 * Esta clase utiliza el patrón singleton para asegurar que sólo exista una instancia de configuración.
	 * Se definen parámetros tales como el modo de creación del sistema, el número de objetos, el tiempo de simulación,
	 * el archivo de datos a cargar y los algoritmos utilizados para la detección de colisiones y la resolución.
	 */
	class Config
	{
	public:
		Config(const Config&) = delete;
		Config& operator=(const Config&) = delete;

		/**
		 * @brief Obtiene la instancia única de Config.
		 * @return Config* Puntero a la instancia de Config.
		 */
		static Config* getConfig();
		
		/// Modo de creación del sistema; por defecto se carga desde archivo.
		Mode _systemCreationMode = Mode::FILE;
		/// Número de objetos a simular.
		int _numObjects = 998;
		/// Tiempo de simulación.
		float _time = 1000;
		/// Nombre del archivo de datos (por defecto "tierra.json").
		char _fichero[100] = "tierra.json";
		/// Algoritmo utilizado para la detección de colisiones (por defecto fuerza bruta).
		Algorithm _collisionAlgorithm = Algorithm::BRUTE_FORCE;
		/// Algoritmo utilizado para la resolución de fuerzas (por defecto fuerza bruta).
		Algorithm _SolverAlgorithm = Algorithm::BRUTE_FORCE;
	private:
		/**
		 * @brief Constructor privado para implementar el patrón singleton.
		 */
		Config() = default;	
	};
}

