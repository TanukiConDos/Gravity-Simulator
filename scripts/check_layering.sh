#!/usr/bin/env bash
# Enforce the engine package boundaries.
#
#   main orchestrates: main -> physics -> front -> backend
#   physics/gpu records compute work through the front's proxy (graphic.compute_*)
#   and speaks only the plain seam types of engine/graphics/shared.
#
# The front never imports physics; the backend imports no ECS/physics; physics
# never touches the backend or Vulkan.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0

fail() {
    local rule="$1" hint="$2" hits="$3"
    echo "check_layering: FAIL — $rule" >&2
    echo "  $hint" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    echo >&2
    failed=1
}

# check <rule> <hint> <pattern> <paths...>
check() {
    local rule="$1" hint="$2" pattern="$3"
    shift 3

    local hits rc
    if hits=$(rg -n --no-heading --color never "$pattern" "$@" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi

    case $rc in
        0) fail "$rule" "$hint" "$hits" ;;
        1) : ;;   # no matches: the rule holds
        *)
            echo "check_layering: rg failed (exit $rc) for: rg -n \"$pattern\" $*" >&2
            exit 2
            ;;
    esac
}

check "engine/graphics/front and engine/graphics/shared must not import vendor:vulkan" \
      "move Vulkan code into engine/graphics/backend; the front proxies it with plain handles" \
      'vendor:vulkan' engine/graphics/front engine/graphics/shared

check "engine/graphics/front must not import the physics packages" \
      "main orchestrates and owns the frame source; physics never points at the front" \
      '^import .*"engine:physics' engine/graphics/front

check "engine/physics must not import the graphics backend" \
      "physics records GPU work through the front's compute API, never through vk" \
      '^import .*"engine:graphics/backend' engine/physics engine/physics/gpu

check "engine/physics must not import vendor:vulkan" \
      "Vulkan types stay behind engine/graphics/backend; physics uses gfx handles" \
      'vendor:vulkan' engine/physics engine/physics/gpu

check "engine/graphics/backend must not import ecs or physics" \
      "the backend is device-level; engine integration belongs to the front" \
      '^import .*"engine:(ecs|physics)' engine/graphics/backend

check "engine/graphics/backend must not depend on the front package" \
      "the dependency goes front -> backend, never backend -> front" \
      'engine:graphics/front' engine/graphics/backend

check "engine/graphics/backend must not declare package graphic" \
      "the front's package name lives only under engine/graphics/front" \
      'package graphic' engine/graphics/backend

if [ "$failed" -ne 0 ]; then
    echo "check_layering: layer violations found (see above)" >&2
    exit 1
fi

echo "check_layering: OK (main orchestrates: physics -> front -> backend, physics speaks gfx only)"
