/**
 * @file OctTree.h
 * @brief Define la clase OctTree para gestionar la partici�n espacial de objetos f�sicos mediante un �rbol octal.
 */

#pragma once
#include <vector>
#include <limits>
#include "PhysicObject.h"
#include <memory>
#include <stack>

#include "PhysicSystem.h"
#include "../../Foundation/Arena.h"

namespace Engine::Physic
{
	/**
		* @class OctTree
		* @brief Clase que implementa un �rbol octal para optimizar c�lculos gravitacionales y detecci�n de colisiones.
		*/
	class OctTree
	{
	private:
		/// Declaraci�n adelantada de la estructura interna Node.
		struct Node;
	public:
		OctTree(const OctTree&) = delete;
		OctTree& operator=(const OctTree&) = delete;

		/**
			* @brief Constructor expl�cito.
			* @param objects Puntero compartido a la colecci�n de objetos f�sicos a gestionar.
			*/
		explicit OctTree(std::shared_ptr<std::vector<PhysicObject>> objects);
			
		/// Constructor por defecto.
		OctTree() = default;

		/**
			* @brief Aplica el algoritmo Barnes-Hut para la simulaci�n de fuerzas.
			* @param deltaTime Intervalo de tiempo transcurrido.
			*/
		glm::vec3 barnesHut(int objectId);
			
		/**
			* @brief Calcula la masa total en cada nodo del �rbol.
			*/
		void massCalculation();
			
		/**
			* @brief Verifica y gestiona colisiones entre objetos.
			*/
		std::vector<int> checkCollisions(int objectId);
			
		/**
			* @brief Actualiza el �rbol y sus elementos.
			*/
		void update(float tickTime);
	private:
		/// Colecci�n de objetos f�sicos.
		std::shared_ptr<std::vector<PhysicObject>> _objects;
		/// Contador de ticks.
		float _tickTime = 0;

		/**
			* @struct ObjectStruct
			* @brief Estructura auxiliar para gestionar objetos en un nodo.
			*/
		struct ObjectStruct {
		public:
			/// Puntero al siguiente objeto en la lista.
			ObjectStruct* _next = nullptr;
			/// �ndice del objeto.
			int _object = -1;

			/**
				* @brief A�ade un objeto a la lista.
				* @param object �ndice del objeto a a�adir.
				* @param arena Arena de asignaci�n de memoria para ObjectStruct.
				*/
			void append(int object, Foundation::Arena<ObjectStruct>& arena)
			{
				if (_object == -1)
				{
					_object = object;
					return;
				}
				if (_next == nullptr) {
					_next = arena.alloc(1);
					*_next = ObjectStruct();
				}
				_next->append(object, arena);
			}

			/**
				* @brief Recupera los �ndices de objetos almacenados.
				* @param objects Vector donde se almacenan los �ndices de los objetos.
				*/
			void get(std::vector<int>& objects)
			{
				if (_next != nullptr)
				{
					_next->get(objects);
				}
				objects.emplace_back(_object);
			}
		};

		/**
			* @struct Node
			* @brief Representa un nodo del �rbol octal.
			*/
		struct Node
		{
		public:
			/**
				* @brief Constructor del nodo.
				* @param start Coordenada de inicio (m�nimo) del nodo.
				* @param end Coordenada final (m�ximo) del nodo.
				*/
			Node(glm::vec3 start, glm::vec3 end);

			/// Ancho del nodo.
			float _width = 0.0f;
			/// Masa acumulada de los objetos en este nodo.
			double _mass = 0.0;
			/// Indica si el nodo no tiene hijos.
			bool _noChilds = true;
			/// Puntero a los nodos hijos.
			Node* _childs = nullptr;
			/// Lista de objetos contenidos en este nodo.
			ObjectStruct* _objects = nullptr;
			/// Profundidad del nodo en el �rbol.
			int _depth = -1;
			/// Coordenadas m�nimas del nodo.
			glm::vec3 _start;
			/// Coordenadas m�ximas del nodo.
			glm::vec3 _end;
			/// Centro del nodo.
			glm::vec3 _center;
		};

		/// Puntero a la ra�z del �rbol octal.
		Node* _root;
		/// Arena de asignaci�n para nodos.
		Foundation::Arena<Node> _arenaNode = Foundation::Arena<Node>(37449);
		/// Arena de asignaci�n para estructuras de objetos.
		Foundation::Arena<ObjectStruct> _arenaObject = Foundation::Arena<ObjectStruct>(37449);
			
		/**
			* @brief Inserta los objetos en el �rbol octal.
			*/
		void insert();
			
		/**
			* @brief Expande un nodo del �rbol, subdividi�ndolo si es necesario.
			* @param node Puntero al nodo a expandir.
			* @param depth Profundidad actual en el �rbol.
			* @return true si el nodo se expandi�, false en caso contrario.
			*/
		bool expand(Node* node, int depth);
	};
}
