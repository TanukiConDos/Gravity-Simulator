# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
```

- Requires Odin compiler (dev-2025-08+) in PATH
- Requires Vulkan SDK installed (vendor:vulkan)

## Project Structure

```
.
├── main.odin               # App entry point + scene JSON loader
├── config.json             # Simulation configuration (edit by hand)
├── engine/
│   ├── graphic/            # Vulkan renderer
│   ├── physic/             # Physics simulation
│   └── state/              # (removed — ImGui UI panels deleted)
├── foundation/             # Config, arena, file I/O, timers
├── tests/                  # Odin test suite
├── Engine/Graphic/shader/  # SPIR-V shaders + GLSL sources + compilar.bat
└── scenes/                 # JSON scene files
```

## Configuration

Simulation parameters are read from `config.json` at startup. It can be edited by hand; missing or invalid fields fall back to defaults.

```json
{
    "system_creation_mode": "FILE",   // "RANDOM" or "FILE"
    "num_objects": 998,               // random objects when mode = RANDOM
    "time": 1000,                     // simulation time multiplier
    "filename": "tierra.json",        // scene file when mode = FILE (in scenes/)
    "collision_algorithm": "BRUTE_FORCE", // "BRUTE_FORCE" or "OCTREE"
    "solver_algorithm": "BRUTE_FORCE"     // "BRUTE_FORCE" or "OCTREE"
}
```

`theta` (Barnes-Hut opening angle, default 0.5) can be added to tune octree approximation vs. accuracy.

## Physics

Config selects algorithms for collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation.

## App Flow

On launch the app loads `config.json`, creates the simulation accordingly (random or from a scene file), and runs until the window closes. Frame/tick timings are logged to the console once per second.

## Tests

4 Google-Test-style tests: `test_octtree_create`, `test_octtree_force`, `test_brute_force`, `test_physic_object`.
