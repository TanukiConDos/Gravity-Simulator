#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
    bool selected;
} ubo;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(inPosition, 1.0);
    vec3 options[2] = vec3[](inColor, vec3(1,inColor.gb));
    fragColor = options[int(ubo.selected)];
}