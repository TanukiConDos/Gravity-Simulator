/**
 * @file Arena.h
 * @brief Implementa un asignador de memoria basado en arena, que gestiona asignaciones dinámicas de objetos en bloques.
 *
 * La clase plantilla Arena permite asignar memoria en bloques continuos, reduciendo las llamadas a malloc/free,
 * y mejorando el rendimiento en aplicaciones con muchas asignaciones dinámicas.
 */

#pragma once
#include <memory>
#include <cstdlib>  // for malloc and free

namespace Foundation
{
	/**
	 * @brief Clase plantilla que gestiona asignaciones en bloques de memoria.
	 *
	 * La clase Arena reserva memoria en bloques y permite la asignación de objetos utilizando una estrategia de arena.
	 *
	 * @tparam T Tipo de objeto a asignar.
	 */
	template <typename T>
	class Arena
	{
	public:

		Arena(const Arena&) = delete;
		Arena& operator=(const Arena&) = delete;

		/**
		 * @brief Constructor.
		 *
		 * Inicializa la arena con una capacidad determinada para el bloque inicial.
		 *
		 * @param capacity Número de objetos que se pueden asignar en el primer bloque.
		 */
		explicit Arena(size_t capacity);

		/**
		 * @brief Destructor.
		 *
		 * Libera los bloques de memoria asignados por la arena.
		 */
		~Arena() { _first.freeBlock(); }

		/**
		 * @brief Asigna memoria para un número de objetos.
		 *
		 * @param num Número de objetos a asignar.
		 * @return T* Puntero a la memoria asignada.
		 */
		T* alloc(int num);

		/**
		 * @brief Reinicializa la arena, permitiendo reutilizar la memoria asignada.
		 */
		void clear();

	private:
		/**
		 * @brief Estructura de bloque de memoria en la arena.
		 *
		 * Cada bloque gestiona un segmento de memoria para asignaciones sucesivas.
		 */
		struct Block
		{
			/// Capacidad máxima del bloque (número de objetos).
			size_t _capacity = 0;
			/// Número de asignaciones realizadas en este bloque.
			size_t _count = 0;
			/// Puntero al inicio del bloque de memoria.
			T* _first = nullptr;
			/// Puntero a la siguiente posición libre en el bloque.
			T* _last = _first;
			/// Bloque siguiente en la cadena.
			std::unique_ptr<Block> _next = nullptr;

			/**
			 * @brief Asigna memoria para un número de objetos dentro del bloque.
			 *
			 * Si el bloque actual no tiene suficiente capacidad, delega la asignación al siguiente bloque.
			 *
			 * @param num Número de objetos a asignar.
			 * @return T* Puntero a la memoria asignada.
			 */
			T* alloc(int num)
			{
				if (_count == _capacity)
				{
					if (_next == nullptr)
					{
						_next = std::make_unique<Block>();
						_next->_capacity = _capacity;
						_next->_first = (T*)malloc(sizeof(T) * _capacity);
						_next->_last = _next->_first;
					}
					return _next->alloc(num);
				}
				T* aux = _last;
				_last += num;
				_count++;
				return aux;
			}

			/**
			 * @brief Reinicializa el bloque, permitiendo reutilizar la memoria asignada.
			 */
			void clear()
			{
				_last = _first;
				_count = 0;
				if (_next != nullptr) _next->clear();
			}

			/**
			 * @brief Libera la memoria asignada en este bloque y en los bloques siguientes.
			 */
			void freeBlock()
			{
				if (_next != nullptr) _next->freeBlock();
				free(_first);
			}
		};
		
		/// Primer bloque de la arena.
		Block _first{};
	};

	template<typename T>
	Arena<T>::Arena(size_t capacity)
	{
		_first._capacity = capacity;
		_first._first = (T*)malloc(sizeof(T) * capacity);
		_first._last = _first._first;
	}

	template<typename T>
	T* Arena<T>::alloc(int num)
	{
		return _first.alloc(num);
	}

	template<typename T>
	void Arena<T>::clear()
	{
		_first.clear();
	}
}

