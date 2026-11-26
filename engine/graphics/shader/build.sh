#!/usr/bin/env bash
# Compiles the GLSL sources into SPIR-V through the shared job table in
# engine/graphics/shader/manifest.odin.
#
# Run from anywhere; the tool runs from the repository root because the manifest
# paths are repository-relative. VULKAN_TARGET_ENV still overrides the target.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$dir/../../.." && pwd)"
cd "$root"

exec odin run tools/shader_build -collection:engine=engine -- "$@"
