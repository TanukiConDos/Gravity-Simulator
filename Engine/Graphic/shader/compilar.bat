@echo off
setlocal
rem Compiles the GLSL sources into SPIR-V for the Vulkan 1.4 graphic engine.
rem Requires the VULKAN_SDK environment variable (set by the Vulkan SDK installer).

if not defined VULKAN_SDK (
    echo error: VULKAN_SDK environment variable is not set
    exit /b 1
)

set "GLSLC=%VULKAN_SDK%\Bin\glslc.exe"
if not exist "%GLSLC%" (
    echo error: glslc not found at "%GLSLC%"
    exit /b 1
)

"%GLSLC%" --target-env=vulkan1.4 "%~dp0vertexShader.vert" -o "%~dp0vert.spv"
"%GLSLC%" --target-env=vulkan1.4 "%~dp0fragmentShader.frag" -o "%~dp0frag.spv"
"%GLSLC%" --target-env=vulkan1.4 "%~dp0pick.vert" -o "%~dp0pick.vert.spv"
"%GLSLC%" --target-env=vulkan1.4 "%~dp0pick.frag" -o "%~dp0pick.frag.spv"

echo shaders compiled ^(target-env=vulkan1.4^) -^> %~dp0
