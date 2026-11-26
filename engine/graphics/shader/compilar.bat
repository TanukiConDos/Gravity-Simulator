@echo off
setlocal
rem Compiles the GLSL sources into SPIR-V through the shared job table in
rem engine/graphics/shader/manifest.odin. Requires the Odin compiler and glslc
rem (the Vulkan SDK installer adds it to PATH or VULKAN_SDK\Bin).

if not defined VULKAN_SDK (
    rem Keep the manifest's default tool lookup; glslc may still be on PATH.
    echo warning: VULKAN_SDK is not set, relying on glslc in PATH
) else (
    set "PATH=%VULKAN_SDK%\Bin;%PATH%"
)

cd /d "%~dp0..\..\.."
odin run tools/shader_build -collection:engine=engine -- %*
exit /b %ERRORLEVEL%
