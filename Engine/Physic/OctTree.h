/**
 * @file OctTree.h
 * @brief Define la clase OctTree para gestionar la partición espacial de objetos físicos mediante un árbol octal.
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
		* @brief Clase que implementa un árbol octal para optimizar cálculos gravitacionales y detección de colisiones.
		*/
	class OctTree
	{
	private:
		/// Declaración adelantada de la estructura interna Node.
		struct Node;
	public:
		OctTree(const OctTree&) = delete;
		OctTree& operator=(const OctTree&) = delete;

		/**
			* @brief Constructor explícito.
			* @param objects Puntero compartido a la colección de objetos físicos a gestionar.
			*/
		explicit OctTree(std::shared_ptr<std::vector<PhysicObject>> objects);
			
		/// Constructor por defecto.
		OctTree() = default;

		/**
			* @brief Aplica el algoritmo Barnes-Hut para la simulación de fuerzas.
			* @param deltaTime Intervalo de tiempo transcurrido.
			*/
		glm::vec3 barnesHut(int objectId);
			
		/**
			* @brief Calcula la masa total en cada nodo del árbol.
			*/
		void massCalculation();
			
		/**
			* @brief Verifica y gestiona colisiones entre objetos.
			*/
		std::vector<int> checkCollisions(int objectId);
			
		/**
			* @brief Actualiza el árbol y sus elementos.
			*/
		void update(float tickTime);
	private:
		/// Colección de objetos físicos.
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
			/// Índice del objeto.
			int _object = -1;

			/**
				* @brief Añade un objeto a la lista.
				* @param object Índice del objeto a añadir.
				* @param arena Arena de asignación de memoria para ObjectStruct.
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
				* @brief Recupera los índices de objetos almacenados.
				* @param objects Vector donde se almacenan los índices de los objetos.
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
			* @brief Representa un nodo del árbol octal.
			*/
		struct Node
		{
		public:
			/**
				* @brief Constructor del nodo.
				* @param start Coordenada de inicio (mínimo) del nodo.
				* @param end Coordenada final (máximo) del nodo.
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
			/// Profundidad del nodo en el árbol.
			int _depth = -1;
			/// Coordenadas mínimas del nodo.
			glm::vec3 _start;
			/// Coordenadas máximas del nodo.
			glm::vec3 _end;
			/// Centro del nodo.
			glm::vec3 _center;
		};

		/// Puntero a la raíz del árbol octal.
		Node* _root;
		/// Arena de asignación para nodos.
		Foundation::Arena<Node> _arenaNode = Foundation::Arena<Node>(37449);
		/// Arena de asignación para estructuras de objetos.
		Foundation::Arena<ObjectStruct> _arenaObject = Foundation::Arena<ObjectStruct>(37449);
			
		/**
			* @brief Inserta los objetos en el árbol octal.
			*/
		void insert();
			
		/**
			* @brief Expande un nodo del árbol, subdividiéndolo si es necesario.
			* @param node Puntero al nodo a expandir.
			* @param depth Profundidad actual en el árbol.
			* @return true si el nodo se expandió, false en caso contrario.
			*/
		bool expand(Node* node, int depth);
	};
}
