#!/usr/bin/env bash
# Compiles the GLSL sources into SPIR-V for the Vulkan 1.4 graphic engine.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${VULKAN_TARGET_ENV:-vulkan1.4}"

if ! command -v glslc >/dev/null 2>&1; then
    echo "error: glslc not found in PATH (install the Vulkan SDK / shaderc)" >&2
    exit 1
fi

glslc --target-env="$target" "$dir/vertexShader.vert" -o "$dir/vert.spv"
glslc --target-env="$target" "$dir/fragmentShader.frag" -o "$dir/frag.spv"
glslc --target-env="$target" "$dir/pick.vert" -o "$dir/pick.vert.spv"
glslc --target-env="$target" "$dir/pick.frag" -o "$dir/pick.frag.spv"

echo "shaders compiled (target-env=$target) -> $dir"
