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
glslc --target-env="$target" "$dir/compute_probe.comp" -o "$dir/compute_probe.spv"
glslc --target-env="$target" "$dir/physics_brute.comp" -o "$dir/physics_brute.spv"
glslc --target-env="$target" "$dir/physics_tree.comp" -o "$dir/physics_tree.spv"

# The GPU tree build is one GLSL source compiled per pass (see its header).
for stage in 0 1 2 3 4 5; do
    glslc --target-env="$target" -DTREE_BUILD_STAGE=$stage "$dir/tree_build.comp" -o "$dir/tree_build_$stage.spv"
done

echo "shaders compiled (target-env=$target) -> $dir"
