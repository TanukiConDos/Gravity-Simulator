#version 460

layout(location = 0) in vec3 fragcolor;
layout(location = 1) flat in uint fragId;

layout(location = 0) out vec4 outColor;
layout(location = 1) out uint outId;

void main() {
    outColor = vec4(fragcolor, 1.0);
    outId = fragId;
}
