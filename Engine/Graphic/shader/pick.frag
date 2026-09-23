#version 460

layout(location = 0) flat in uint inId;
layout(location = 0) out uint outId;

void main() {
    outId = inId;
}
