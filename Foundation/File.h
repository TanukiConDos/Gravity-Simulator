/**
 * @file File.h
 * @brief Proporciona funcionalidades para la lectura y escritura de archivos, útil para cargar shaders u otros recursos.
 */

#pragma once
#include <fstream>
#include <string>
#include <vector>

namespace Foundation
{
	/**
	 * @class File
	 * @brief Clase que gestiona la lectura y escritura de archivos.
	 *
	 * Esta clase permite abrir un archivo, leer su contenido completo como un vector de caracteres,
	 * obtener su tamaño y escribir datos en él.
	 */
	class File
	{
	public:
		File(const File&) = delete;
		File& operator=(const File&) = delete;

		/**
		 * @brief Constructor.
		 *
		 * Abre el archivo indicado por el nombre, considerando si es un shader u otro tipo de recurso.
		 *
		 * @param filename Nombre del archivo a abrir.
		 * @param isShader Valor booleano que indica si el archivo es un shader (true por defecto).
		 */
		File(std::string const &filename, bool isShader = true);

		/**
		 * @brief Destructor.
		 *
		 * Cierra el archivo y libera los recursos asociados.
		 */
		~File();

		/**
		 * @brief Obtiene el tamaño del archivo.
		 *
		 * @return size_t Tamaño del archivo en bytes.
		 */
		size_t getSize() const { return _size; };

		/**
		 * @brief Lee todo el contenido del archivo.
		 *
		 * @return std::vector<char> Vector de caracteres que contiene el contenido del archivo.
		 */
		std::vector<char> read();

		/**
		 * @brief Escribe datos en el archivo.
		 *
		 * @param data Cadena de caracteres con los datos a escribir.
		 */
		void write(std::string const & data);

	private:
		/// Flujo de archivo utilizado para la lectura/escritura.
		std::fstream _file;
		/// Tamaño del archivo en bytes.
		size_t _size;
	};
}

