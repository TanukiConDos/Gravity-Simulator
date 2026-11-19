#!/usr/bin/env bash
# Enforce the Engine/Graphic package boundaries:
#
#   front (package graphic) -> backend (package vk) -> shared (package gfx)
#
# The front never imports Vulkan; the backend never imports the front.
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

check "Engine/Graphic/backend must not import ecs or physic" \
      "the backend is device-level; engine integration belongs to front/gpu" \
      '^import (ecs|physic|phys) ' Engine/Graphic/backend

check "Engine/Graphic/backend must not depend on the front package" \
      "the dependency goes front -> backend, never backend -> front" \
      'Graphic/front' Engine/Graphic/backend

check "Engine/Graphic/backend must not declare package graphic" \
      "the front's package name lives only under Engine/Graphic/front" \
      'package graphic' Engine/Graphic/backend

check "Engine/Graphic/front must not import the GPU physics package" \
      "the front holds an opaque vk.Stream_Handle; main wires the producer" \
      'physic/gpu|Gpu_Gravity' Engine/Graphic/front

check "Engine/physic/gpu must not import the front package" \
      "the front consumes the producer through the backend's Stream_Handle" \
      'Graphic/front' Engine/physic/gpu

if [ "$failed" -ne 0 ]; then
    echo "check_layering: layer violations found (see above)" >&2
    exit 1
fi

echo "check_layering: OK (front -> backend -> shared; physic/gpu -> backend)"
