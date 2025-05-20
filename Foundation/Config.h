/**
 * @file Config.h
 * @brief Gestiona la configuraci�n de la aplicaci�n, permitiendo obtener par�metros como el modo de creaci�n del sistema,
 * el n�mero de objetos, el tiempo de simulaci�n, el archivo de datos y los algoritmos para colisiones y resoluci�n.
 */

#pragma once
#include <map>
#include <string>

namespace Foundation
{
	/**
	 * @enum Algorithm
	 * @brief Enumera los algoritmos disponibles para la detecci�n de colisiones y resoluci�n de fuerzas.
	 *
	 * - BRUTE_FORCE: Utiliza fuerza bruta para calcular interacciones (verifica cada pareja de objetos).
	 * - OCTREE: Utiliza un �rbol octal para optimizar los c�lculos reduciendo la complejidad.
	 */
	enum class Algorithm
	{
		BRUTE_FORCE = 0,
		OCTREE = 1
	};
	
	/**
	 * @enum Mode
	 * @brief Define el modo de creaci�n de sistemas para la simulaci�n.
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
	 * @brief Clase que maneja la configuraci�n global de la aplicaci�n.
	 *
	 * Esta clase utiliza el patr�n singleton para asegurar que s�lo exista una instancia de configuraci�n.
	 * Se definen par�metros tales como el modo de creaci�n del sistema, el n�mero de objetos, el tiempo de simulaci�n,
	 * el archivo de datos a cargar y los algoritmos utilizados para la detecci�n de colisiones y la resoluci�n.
	 */
	class Config
	{
	public:
		Config(const Config&) = delete;
		Config& operator=(const Config&) = delete;

		/**
		 * @brief Obtiene la instancia �nica de Config.
		 * @return Config* Puntero a la instancia de Config.
		 */
		static Config* getConfig();
		
		/// Modo de creaci�n del sistema; por defecto se carga desde archivo.
		Mode _systemCreationMode = Mode::FILE;
		/// N�mero de objetos a simular.
		int _numObjects = 998;
		/// Tiempo de simulaci�n.
		float _time = 1000;
		/// Nombre del archivo de datos (por defecto "tierra.json").
		char _fichero[100] = "tierra.json";
		/// Algoritmo utilizado para la detecci�n de colisiones (por defecto fuerza bruta).
		Algorithm _collisionAlgorithm = Algorithm::BRUTE_FORCE;
		/// Algoritmo utilizado para la resoluci�n de fuerzas (por defecto fuerza bruta).
		Algorithm _SolverAlgorithm = Algorithm::BRUTE_FORCE;
	private:
		/**
		 * @brief Constructor privado para implementar el patr�n singleton.
		 */
		Config() = default;	
	};
}

