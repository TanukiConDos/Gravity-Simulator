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
"%GLSLC%" --target-env=vulkan1.4 "%~dp0compute_probe.comp" -o "%~dp0compute_probe.spv"
"%GLSLC%" --target-env=vulkan1.4 "%~dp0physics_brute.comp" -o "%~dp0physics_brute.spv"
"%GLSLC%" --target-env=vulkan1.4 "%~dp0physics_tree.comp" -o "%~dp0physics_tree.spv"

rem The GPU tree build is one GLSL source compiled per pass.
for %%S in (0 1 2 3 4 5) do (
    "%GLSLC%" --target-env=vulkan1.4 -DTREE_BUILD_STAGE=%%S "%~dp0tree_build.comp" -o "%~dp0tree_build_%%S.spv"
)

echo shaders compiled ^(target-env=vulkan1.4^) -^> %~dp0
