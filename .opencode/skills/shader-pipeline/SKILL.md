---
name: Shader Pipeline
description: Use when editing GLSL shaders or the data-driven Vulkan pipeline (vertex attributes, descriptors, frame graph) under Engine/Graphic.
---

# Shader pipeline

The renderer is built from data, not hand-written Vulkan structs. Read
`docs/renderer.md` for the full contract before changing the pipeline.

## After editing any shader

GLSL sources live in `Engine/Graphic/shader/`. The app loads the committed
SPIR-V, so a `.vert`/`.frag` edit does nothing until you recompile:

```
Engine/Graphic/shader/build.sh        # Linux
Engine/Graphic/shader/compilar.bat    # Windows (needs VULKAN_SDK)
```

Targets SPIR-V 1.6 (`--target-env=vulkan1.4`). Rebuild before running or testing.

## Adding a vertex attribute

Attributes are paired by declarative order, and a mismatch fails at pipeline
build time with a log error:

1. Add the input to the GLSL interface.
2. Add the field to the packed CPU struct (in declaration order) named by the
   `Vertex_Buffer_Spec`.

Formats come from SPIR-V; offsets and strides from the struct. The struct's
non-`_` fields consume the shader input locations in ascending order.

## Adding a resource / binding

1. Add it to the GLSL interface.
2. Register it in `renderer_config.odin` (single source of truth; types live in
   `pipeline_config.odin`).

`descriptors.odin` pushes bindings with `vkCmdPushDescriptorSet2`, and
`push_descriptors_validate` checks each configured binding against the shader
interface.

## Frame graph

`Engine/Graphic/frame_graph.json` owns the structure (resources, passes,
`inputs`/`outputs`, `bindings`, `optional`). `frame_graph.odin` culls, topo-sorts
and executes it; passes bind to code by name in `_renderer_record_pass`. Add a
pass in the JSON and implement its record callback in the renderer.

## Verify

- `odin test tests -debug` runs the SPIR-V reflection unit tests, which read the
  engine shaders plus the committed fixture in `tests/fixtures/` (rebuild it with
  `tests/fixtures/build.sh` if the interface fixture changed).
- Run the app with `VK_LAYER_KHRONOS_validation` enabled to catch pipeline and
  barrier mistakes (see the Validation section of `AGENTS.md`).
