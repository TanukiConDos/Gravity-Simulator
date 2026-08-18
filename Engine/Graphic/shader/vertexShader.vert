#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 view;
    mat4 proj;
} ubo;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;
layout(location = 2) in vec3 instancePos;
layout(location = 3) in float instanceRadius;
layout(location = 4) in int instanceSelected;

layout(location = 0) out vec3 fragColor;

void main() {
    mat4 model = mat4(
        vec4(instanceRadius, 0.0, 0.0, 0.0),
        vec4(0.0, instanceRadius, 0.0, 0.0),
        vec4(0.0, 0.0, instanceRadius, 0.0),
        vec4(instancePos, 1.0)
    );
    gl_Position = ubo.proj * ubo.view * model * vec4(inPosition, 1.0);
    vec3 options[2] = vec3[](inColor, vec3(1, inColor.gb));
    fragColor = options[int(instanceSelected)];
}
