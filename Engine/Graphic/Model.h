/**
 * @file Model.h
 * @brief Define la clase Model para representar modelos 3D generados a partir de par�metros geom�tricos.
 *
 * Esta clase se encarga de generar v�rtices e �ndices utilizando valores como sectorCount y stackCount,
 * y de gestionar el buffer en la GPU para renderizar el modelo.
 */

#pragma once
#include "GPU.h"
#include "../Physic/PhysicObject.h"
#include "CommandPool.h"
#include "Buffer.h"
const float PI = 3.141592653589793238462643383279502884f;

namespace Engine::Graphic
{
	/**
		* @class Model
		* @brief Representa un modelo 3D generado a partir de par�metros geom�tricos.
		*
		* La clase Model se utiliza para generar la malla del modelo, almacenar los v�rtices e �ndices,
		* y crear el buffer correspondiente en la GPU para su renderizaci�n.
		*/
	class Model
	{
	public:
		Model(const Model&) = delete;
		Model& operator=(const Model&) = delete;
			
		/**
			* @brief Constructor de Model.
			*
			* Genera la malla del modelo utilizando el n�mero de sectores y pilas indicados,
			* e inicializa los recursos necesarios en la GPU mediante la GPU y el CommandPool proporcionados.
			*
			* @param sectorCount N�mero de divisiones alrededor del eje (sectores).
			* @param stackCount N�mero de divisiones en la direcci�n vertical (pilas).
			* @param gpu Referencia a la GPU para crear los buffers.
			* @param commandPool Pool de comandos utilizado para la creaci�n de comandos de copia.
			*/
		Model(int sectorCount, int stackCount, GPU& gpu, CommandPool& commandPool);
			
		/**
			* @brief Enlaza el buffer del modelo al buffer de comando para el renderizado.
			*
			* Este m�todo vincula el buffer que contiene la malla del modelo al comando de renderizaci�n.
			*
			* @param commandBuffer Buffer de comando donde se enlaza el buffer.
			*/
		void bind(VkCommandBuffer commandBuffer) const;
			
		/**
			* @brief Obtiene el n�mero total de �ndices del modelo.
			*
			* Este valor se utiliza para determinar la cantidad de elementos a renderizar.
			*
			* @return size_t N�mero de �ndices almacenados.
			*/
		size_t getIndexSize() const;

	private:
		/// Vector que almacena los v�rtices del modelo.
		std::vector<Vertex> _modelVertex = std::vector<Vertex>{};
		/// Vector que almacena los �ndices del modelo.
		std::vector<int> _index = std::vector<int>{};
		/// Referencia a la GPU para gestionar los recursos gr�ficos.
		GPU& _gpu;
		/// Buffer que almacena la malla del modelo en la GPU.
		std::unique_ptr<Buffer> _buffer;
	};
}