#!/usr/bin/env bash
# Enforce the engine package boundaries.
#
#   main -> physic -> front -> backend
#   physic/gpu, physic/render -> front -> backend
#
# The front never imports physics; the backend imports no ECS/physics.
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

check "Engine/Graphic/front and Engine/Graphic/shared must not import vendor:vulkan" \
      "move Vulkan code into Engine/Graphic/backend" \
      'vendor:vulkan' Engine/Graphic/front Engine/Graphic/shared

check "Engine/Graphic/front must not import the physics packages" \
      "physics integrates with the front, never the other way round" \
      '^import (phys|physic|physic_gpu|physic_render) ' Engine/Graphic/front

check "Engine/Graphic/backend must not import ecs or physic" \
      "the backend is device-level; engine integration belongs to physic/render and the front" \
      '^import (ecs|physic|phys) ' Engine/Graphic/backend

check "Engine/Graphic/backend must not depend on the front package" \
      "the dependency goes front -> backend, never backend -> front" \
      'Graphic/front' Engine/Graphic/backend

check "Engine/Graphic/backend must not declare package graphic" \
      "the front's package name lives only under Engine/Graphic/front" \
      'package graphic' Engine/Graphic/backend

check "Engine/physic core must not depend on the graphics front" \
      "only Engine/physic/render and Engine/physic/gpu may integrate with graphics" \
      'Graphic/front' Engine/physic/*.odin

if [ "$failed" -ne 0 ]; then
    echo "check_layering: layer violations found (see above)" >&2
    exit 1
fi

echo "check_layering: OK (main -> physic -> front -> backend)"
