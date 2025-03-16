/**
 * @file PhysicObject.h
 * @brief Define la clase PhysicObject para representar un objeto f�sico en la simulaci�n,
 * proporcionando m�todos para actualizar su estado, gestionar colisiones y serializar a JSON.
 */

#pragma once
#include <glm/glm.hpp>
#include "../../External/json/json.hpp"

namespace Engine::Physic
{
	/**
		* @class PhysicObject
		* @brief Representa un objeto f�sico en la simulaci�n.
		*
		* La clase permite actualizar el estado del objeto en funci�n de un intervalo de tiempo y una fuerza aplicada,
		* gestionar colisiones con otros objetos y obtener la velocidad actual. Adem�s, sus datos pueden ser serializados/deserializados a formato JSON.
		*/
	class PhysicObject
	{
	public:
		/**
			* @brief Constructor que inicializa un objeto f�sico.
			*
			* @param position Posici�n inicial del objeto.
			* @param velocity Velocidad inicial del objeto.
			* @param mass Masa del objeto.
			* @param radius Radio del objeto.
			*/
		PhysicObject(glm::vec3 position, glm::vec3 velocity, float mass, float radius);

		/**
			* @brief Actualiza el estado del objeto.
			*
			* Aplica la fuerza dada durante el intervalo de tiempo especificado para actualizar la posici�n y velocidad.
			*
			* @param deltaTime Intervalo de tiempo transcurrido.
			* @param force Fuerza aplicada al objeto.
			*/
		void update(float deltaTime, glm::vec3 force);

		/**
			* @brief Gestiona la colisi�n con otro objeto f�sico.
			*
			* Actualiza el estado del objeto en funci�n de la colisi�n ocurrida con otro objeto.
			*
			* @param object Referencia al objeto con el que se ha colisionado.
			*/
		void collision(PhysicObject& object);

		/**
			* @brief Obtiene la velocidad actual del objeto.
			*
			* Calcula y retorna la longitud del vector velocidad.
			*
			* @return float Velocidad del objeto.
			*/
		float getVelocity() const { return glm::length(_velocity); }

		/// Posici�n actual del objeto.
		glm::vec3 _position;
		/// Velocidad actual del objeto.
		glm::vec3 _velocity;
		/// Aceleraci�n del objeto (inicialmente 0).
		glm::vec3 _acceleration = glm::vec3(0.0, 0.0, 0.0);
		/// Masa del objeto.
		double _mass;
		/// Radio del objeto.
		float _radius;
		/// Indica si el objeto est� seleccionado.
		bool _selected = false;
	};

	/**
		* @brief Serializa un objeto PhysicObject a formato JSON.
		*
		* Convierte los atributos del objeto f�sico a un objeto JSON.
		*
		* @param j Referencia al objeto JSON donde se almacenan los datos.
		* @param o Objeto PhysicObject a serializar.
		*/
	void to_json(nlohmann::json& j, const PhysicObject& o);

	/**
		* @brief Deserializa un objeto PhysicObject desde formato JSON.
		*
		* Restaura los atributos del objeto f�sico a partir de la informaci�n contenida en el JSON.
		*
		* @param j Objeto JSON que contiene los datos.
		* @param o Objeto PhysicObject que se actualizar�.
		*/
	void from_json(const nlohmann::json& j, PhysicObject& o);
}