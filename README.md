[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=TanukiConDos_TFG&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=TanukiConDos_TFG)
# Simulador de Campos Gravitatorios

## Descripci�n
Este proyecto es una aplicaci�n desarrollada en C++20 que se enfoca en aprender las bases de la computaci�n gr�fica y la simulaciones de fenomenos f�sicos.
Especi�ficamente, se trata de un simulador de campos gravitatorios que permite al usuario definir las condiciones iniciales de los cuerpos celestes y observar su interacci�n gravitatoria.
Las herramientas utilizadas para el desarrollo de este proyecto son las siguientes:
- [Vulkan](https://www.vulkan.org/): API de gr�ficos de bajo nivel.
- [GLFW](https://www.glfw.org/): Biblioteca para la creaci�n de ventanas y la gesti�n de eventos.
- [GLM](https://glm.g-truc.net): Biblioteca de matem�ticas para gr�ficos en 3D.
- [ImGui](https://github.com/ocornut/imgui): Biblioteca para la creaci�n de interfaces de usuario.
- [json](https://json.nlohmann.me/): Biblioteca para el manejo de archivos JSON.

## Instalaci�n
Descarga el zip de la �ltima versi�n del proyecto desde la p�gina de [releases]() y descompr�melo en la carpeta que prefieras.

Ejecuta el archivo `SimuladorCamposGravitatorios.exe` para iniciar la aplicaci�n.

## Uso de la aplicaci�n

La aplicaci�n cuenta con una interfaz gr�fica que permite al usuario definir una serie de par�metros utilizados en la aplicaci�n. Estos par�metros se cambian en la ventana de c�nfiguraci�n de la aplicaci�n.
Los p�rametros son los siguientes:

- **Multiplicador de tiempo**: Se encarga de establecer la relaci�n entre el tiempo en la simulaci�n y la vida real. Por ejemplo, con el valor en 1000 un segundo en la vida real son 1000 segundos en la simulaci�n.
- **Modo de creaci�n de la escenca**: Permite seleccionar de donde saca los valores iniciales de la simulaci�n. Puede ser JSON o aleatorio. Los JSON tienen que estar en la carpeta scenes.�
- **Fichero JSON/n�mero de objetos**: Esta opci�n cambia dependiendo del valor en el par�metro anterior. En el fichero JSON se establerce el nombre del fichero del que se leen los datos. El n�mero de objetos cambia el numero de cuerpos a generar de manera aleatoria.
- **Algoritmo de colisi�n**: Permite elegir el algoritmo que resuelve la colisi�n entre 2 cuerpos.
- **Algoritmo de Resoluci�n**: Permite elegir el algoritmo que calcula la fuerza gravitatoria entre los cuerpos.

![imagen de la configuraci�n]()


Una vez configurada la simulaci�n podemos pulsar en iniciar simulaci�n. Esto nos lleva a una pantalla en la que se ve la simulaci�n en tiempo real y 2 ventanas.
- **La ventana de debug**: Muestra estadisticas de cuanto tarda en realizar la renderizaci�n y los calculos del motor de f�sicas.
- **Datos del cuerpo**: Muestra los datos del cuerpo selecionado.

![imagen de la simulaci�n]()

## Compilaci�n desde c�digo fuente
1. **Requisitos previos:**
   - Sistema operativo Windows.
   - [Visual Studio 2022](https://visualstudio.microsoft.com/vs/) con soporte para C++ y C++20.
   - Descargar e instalar [Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows).
   - Descargar e instalar [GLFW](https://www.glfw.org/download.html).
   - Descargar e instalar [GLM](https://github.com/g-truc/glm/releases).

2. **Preparaci�n del entorno:**

   Abre el archivo `SimuladorCamposGravitatorios.sln` con Visual Studio 2022. En la configuraci�n de la soluci�n, aseg�rate de que las rutas de las librer�as de Vulkan,
   GLFW y GLM sean las rutas en las que te has descargado las librerias. Para ello, ve a `Propiedades de la soluci�n -> Configuraci�n de propiedades -> C/C++ -> Directorios de inclusi�n adicionales` 
   y a�ade las rutas a la carpeta include de las librer�as.

   A continuaci�n, ve a `Propiedades de la soluci�n -> Configuraci�n de propiedades -> Vinculador -> Directorios de bibliotecas adicionales` y a�ade las rutas a las carpetas lib de las librer�as.

   Ya puedes compilar el proyecto y ejecutarlo.