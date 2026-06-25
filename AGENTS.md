# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
```

- Requires Odin compiler (dev-2025-08+) in PATH
- Requires Vulkan SDK installed (vendor:vulkan)
- Requires `External/odin-imgui/` (zeozeozeo/odin-imgui — vendored ImGui v1.91.x-docking with GLFW + Vulkan backends, pre-built `.lib`)

## Project Structure

```
.
├── main.odin               # App entry point + scene JSON loader
├── engine/
│   ├── graphic/            # Vulkan renderer + ImGui
│   ├── physic/             # Physics simulation
│   └── state/              # State machine + ImGui UI panels
├── foundation/             # Config, arena, file I/O, timers
├── tests/                  # Odin test suite
├── Engine/Graphic/shader/  # SPIR-V shaders + GLSL sources + compilar.bat
├── scenes/                 # JSON scene files
├── External/odin-imgui/    # Vendored ImGui bindings
└── imgui.ini               # ImGui window layout persistence
```

## ImGui

Uses `zeozeozeo/odin-imgui` (L-4 fork) — `dear_bindings`-generated C API with Vulkan + GLFW backends.
- No allocator setup needed
- Uses `imgvk.LoadFunctions` before `Init` (`.lib` compiled with `VK_NO_PROTOTYPES`)
- ImGui renders into the same render pass (subpass 0) as the 3D scene

## Physics

Config selects algorithms for collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation.

## State Machine

MainMenu → Config → Debug (with ObjectSelected overlay). ImGui windows are rendered between `imgui_manager_new_frame()` and `imgui_manager_end_frame()`.

## Tests

4 Google-Test-style tests: `test_octtree_create`, `test_octtree_force`, `test_brute_force`, `test_physic_object`.
