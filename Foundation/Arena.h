#pragma once
#include<memory>
namespace Foundation
{
	template <typename T>
	class Arena
	{
	public:

		Arena(const Arena&) = delete;
		Arena& operator=(const Arena&) = delete;

		explicit Arena(size_t capacity);

		~Arena() { _first.freeBlock(); }


		T* alloc(int num);


		void clear();

	private:
		
		struct Block
		{
			size_t _capacity = 0;
			size_t _count = 0;
			T* _first = nullptr;
			T* _last = _first;
			std::unique_ptr<Block> _next = nullptr;

			T* alloc(int num)
			{
				if (_count == _capacity)
				{
					if (_next == nullptr)
					{
						_next = std::make_unique<Block>();
						_next->_capacity = _capacity;
						_next->_first = (T*)malloc(sizeof(T) * _capacity);
						_next->_last = _first;
					}
					return _next->alloc(num);
				}
				T* aux = _last;
				_last += num;
				_count++;
				return aux;
			}
			void clear()
			{
				_last = _first;
				_count = 0;
				if (_next != nullptr) _next->clear();
			}

			void freeBlock()
			{
				if (_next != nullptr) _next->freeBlock();
				free(_first);
			}
		};
		
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

