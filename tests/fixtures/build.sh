#!/usr/bin/env bash
# Rebuilds the SPIR-V fixtures used by the shader reflection tests.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

glslc --target-env="vulkan1.4" "$dir/probe.frag" -o "$dir/probe_frag.spv"

echo "fixtures compiled -> $dir"
