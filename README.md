[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=TanukiConDos_TFG&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=TanukiConDos_TFG)
# Simulador de Campos Gravitatorios

## Descripción
Este proyecto es una aplicación desarrollada en C++20 que se enfoca en aprender las bases de la computación gráfica y la simulaciones de fenomenos físicos.
Especiíficamente, se trata de un simulador de campos gravitatorios que permite al usuario definir las condiciones iniciales de los cuerpos celestes y observar su interacción gravitatoria.
Las herramientas utilizadas para el desarrollo de este proyecto son las siguientes:
- [Vulkan](https://www.vulkan.org/): API de gráficos de bajo nivel.
- [GLFW](https://www.glfw.org/): Biblioteca para la creación de ventanas y la gestión de eventos.
- [GLM](https://glm.g-truc.net): Biblioteca de matemáticas para gráficos en 3D.
- [ImGui](https://github.com/ocornut/imgui): Biblioteca para la creación de interfaces de usuario.
- [json](https://json.nlohmann.me/): Biblioteca para el manejo de archivos JSON.
- [EnkiTS](https://github.com/dougbinks/enkiTS): Biblioteca para la gestión de tareas y hilos.

## Instalación
Descarga el zip de la última versión del proyecto desde la página de [releases]() y descomprímelo en la carpeta que prefieras.

Ejecuta el archivo `SimuladorCamposGravitatorios.exe` para iniciar la aplicación.

## Uso de la aplicación

La aplicación cuenta con una interfaz gráfica que permite al usuario definir una serie de parámetros utilizados en la aplicación. Estos parámetros se cambian en la ventana de cónfiguración de la aplicación.
Los párametros son los siguientes:

- **Multiplicador de tiempo**: Se encarga de establecer la relación entre el tiempo en la simulación y la vida real. Por ejemplo, con el valor en 1000 un segundo en la vida real son 1000 segundos en la simulación.
- **Modo de creación de la escenca**: Permite seleccionar de donde saca los valores iniciales de la simulación. Puede ser JSON o aleatorio. Los JSON tienen que estar en la carpeta scenes.ç
- **Fichero JSON/número de objetos**: Esta opción cambia dependiendo del valor en el parámetro anterior. En el fichero JSON se establerce el nombre del fichero del que se leen los datos. El número de objetos cambia el numero de cuerpos a generar de manera aleatoria.
- **Algoritmo de colisión**: Permite elegir el algoritmo que resuelve la colisión entre 2 cuerpos.
- **Algoritmo de Resolución**: Permite elegir el algoritmo que calcula la fuerza gravitatoria entre los cuerpos.

![image](https://github.com/user-attachments/assets/002a02bb-ecdf-4777-b890-5ca9421e6a36)


Una vez configurada la simulación podemos pulsar en iniciar simulación. Esto nos lleva a una pantalla en la que se ve la simulación en tiempo real y 2 ventanas.
- **La ventana de debug**: Muestra estadisticas de cuanto tarda en realizar la renderización y los calculos del motor de físicas.
- **Datos del cuerpo**: Muestra los datos del cuerpo selecionado.

![image](https://github.com/user-attachments/assets/bac0c520-61ef-4081-a132-24fd5c3f4ae9)


## Compilación desde código fuente
1. **Requisitos previos:**
   - Sistema operativo Windows.
   - [Visual Studio 2022](https://visualstudio.microsoft.com/vs/) con soporte para C++ y C++20.
   - Descargar e instalar [Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows).
   - Descargar e instalar [GLFW](https://www.glfw.org/download.html).
   - Descargar e instalar [GLM](https://github.com/g-truc/glm/releases).

2. **Preparación del entorno:**

   Abre el archivo `SimuladorCamposGravitatorios.sln` con Visual Studio 2022. En la configuración de la solución, asegúrate de que las rutas de las librerías de Vulkan,
   GLFW y GLM sean las rutas en las que te has descargado las librerias. Para ello, ve a `Propiedades de la solución -> Configuración de propiedades -> C/C++ -> Directorios de inclusión adicionales` 
   y añade las rutas a la carpeta include de las librerías.

   A continuación, ve a `Propiedades de la solución -> Configuración de propiedades -> Vinculador -> Directorios de bibliotecas adicionales` y añade las rutas a las carpetas lib de las librerías.

   Ya puedes compilar el proyecto y ejecutarlo.

   Para la ejecución de los test se debe añadir la ruta de la librería GLM a los directorios de inclusión adicionales siguiendo el mismo procedimiento que antes en el projecto de test.