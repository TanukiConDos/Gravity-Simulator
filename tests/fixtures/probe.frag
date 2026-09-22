#version 460

// Reflection probe: a combined image sampler, a push constant block
// (vec4 + mat4 = 80 bytes) and a regular fragment input/output.

layout(set = 0, binding = 1) uniform sampler2D uTexture;

layout(push_constant) uniform Push {
    vec4 tint;
    mat4 transform;
} pc;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(uTexture, uv) * pc.tint * pc.transform[0];
}
