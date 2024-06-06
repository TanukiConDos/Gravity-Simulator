#pragma once

namespace Foundation
{
	template <typename T>
	class Arena
	{
	public:

		Arena(const Arena&) = delete;
		Arena& operator=(const Arena&) = delete;

		Arena(size_t capacity);

		~Arena() { free(first); }


		T* alloc(int num);


		void clear();

	private:
		size_t capacity;
		T* first;
		T* last;

	};

	template<typename T>
	Arena<T>::Arena(size_t capacity) : capacity(capacity)
	{
		first = (T*)malloc(sizeof(T) * capacity);
		last = first;
	}

	template<typename T>
	T* Arena<T>::alloc(int num)
	{
		if (last + num >= first + capacity) return nullptr;
		T* aux = last;
		last += num;
		return aux;
	}

	template<typename T>
	void Arena<T>::clear()
	{
		last = first;
	}


}

