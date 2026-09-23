[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=TanukiConDos_TFG&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=TanukiConDos_TFG)
# Simulador de Campos Gravitatorios

## Descripción
Este proyecto es una aplicación desarrollada en [Odin](https://odin-lang.org/) que se enfoca en aprender las bases de la computación gráfica y la simulaciones de fenomenos físicos.
Especiíficamente, se trata de un simulador de campos gravitatorios que permite al usuario definir las condiciones iniciales de los cuerpos celestes y observar su interacción gravitatoria.
Las herramientas utilizadas para el desarrollo de este proyecto son las siguientes:
- [Vulkan](https://www.vulkan.org/): API de gráficos de bajo nivel.
- [GLFW](https://www.glfw.org/): Biblioteca para la creación de ventanas y la gestión de eventos (a través de los bindings de Odin).

## Instalación
Descarga el zip de la última versión del proyecto desde la página de [releases](https://github.com/TanukiConDos/TFG/releases) y descomprímelo en la carpeta que prefieras.

Ejecuta el archivo `GravitySimulator.exe` para iniciar la aplicación.

## Uso de la aplicación

Los parámetros de la simulación se configuran editando a mano el archivo `config.json`, que se lee al iniciar la aplicación:

- **system_creation_mode**: De dónde se toman los valores iniciales de la simulación. Puede ser `"FILE"` (se carga un fichero de la carpeta scenes) o `"RANDOM"` (se generan cuerpos de forma aleatoria).
- **num_objects**: Número de cuerpos generados cuando el modo de creación es `"RANDOM"`.
- **time**: Multiplicador de tiempo. Relación entre el tiempo de la simulación y el tiempo real. Por ejemplo, con el valor en 1000 un segundo en la vida real son 1000 segundos en la simulación.
- **filename**: Nombre del fichero JSON a cargar (en la carpeta scenes) cuando el modo de creación es `"FILE"`.
- **algorithm**: Algoritmo usado tanto para calcular la gravedad (solver) como para detectar y resolver las colisiones. Puede ser `"BRUTE_FORCE"` u `"OCTREE"`.
- **tree_rebuild_interval**: Intervalo (en segundos de simulación) entre reconstrucciones del octree. Un valor de `0` reconstruye el árbol en cada tick.
- **max_depth**: Límite de profundidad del octree (por defecto 48). El árbol natural para N cuerpos suele quedarse cerca de `log8(N)`, por lo que valores de 8–16 ya acotan el caso patológico sin coste apreciable.
- **min_half_size**: Tamaño mínimo de celda hoja del octree (por defecto `0.0001`).
- **worker_threads**: Número de hilos usados para paralelizar el solver de gravedad (octree).
- **auto_adjust**: Si es `true`, `theta` y el intervalo de reconstrucción del octree se ajustan automáticamente para mantener la velocidad objetivo de simulación.
- **target_tickrate**: Actualizaciones de física por segundo objetivo (por defecto 60) cuando `auto_adjust` está activo.
- **theta_min** / **theta_max**: Límites del rango en el que `theta` se puede ajustar cuando `auto_adjust` está activo.

Una vez iniciada, la simulación se ejecuta en tiempo real hasta que se cierra la ventana. Las estadísticas de rendimiento (frametime y ticktime) se muestran por consola una vez por segundo.

## Compilación desde código fuente
1. **Requisitos previos:**
   - [Compilador de Odin](https://odin-lang.org/) (dev-2025-08 o posterior) en el PATH.
   - Descargar e instalar [Vulkan SDK](https://vulkan.lunarg.com/sdk/home#windows).

2. **Preparación del entorno:**

   Asegúrate de que el compilador de Odin y el Vulkan SDK están disponibles en el PATH. Para compilar los shaders, edita el script `compilar.bat` en la carpeta `Engine/Graphic/shader` cambiando la ruta del compilador de shaders de Vulkan a la ruta en la que hallas instalado el SDK.

3. **Compilación y ejecución:**

   Ejecuta `odin run . -debug` desde la raíz del proyecto para compilar y lanzar la aplicación. La simulación se ejecuta en tiempo real hasta que se cierra la ventana.

   Para builds optimizadas puedes añadir `-microarch:native`, que permite al compilador usar las instrucciones SIMD (AVX) de tu CPU. Por defecto Odin solo apunta a SSE2. Usa `-microarch:haswell` si quieres un binario AVX2 portable, u omite el flag para un binario genérico:

   ```
   odin build . -o:speed -disable-assert -microarch:native
   ```

4. **Ejecución de los tests:**

   Ejecuta `odin test tests -debug` desde la raíz del proyecto para compilar y lanzar la suite de tests.

5. **Benchmark del octree:**

   El directorio `bench/` barre los parámetros del octree (profundidad máxima, `theta`, intervalo de reconstrucción y número de hilos) midiendo tiempo por tick y error de precisión frente a una referencia exacta. Los resultados se escriben en `bench/results/`:

   ```
   odin run bench -o:speed -disable-assert -microarch:native            # todas las etapas
   odin run bench -o:speed -disable-assert -microarch:native -- 10k     # sólo una etapa (1k | 10k | 100k)
   ```

   Para generar una traza de perfilado con [`spall`](https://gravitymoth.com/spall/) (`core:prof`), compila con `-define:PROFILE=true` y usa la etapa `profile`:

   ```
   odin run bench -o:speed -disable-assert -microarch:native -define:PROFILE=true -- profile 100000 16 0.5 50 16
   ```

   Escribe `bench/results/trace_*.spall`, que puede abrirse en el visor de spall o en Perfetto. No uses `-define:PROFILE=true` para medir tiempos: deja las llamadas de instrumentación en el binario y altera los resultados.
