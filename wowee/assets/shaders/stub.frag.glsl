#version 450

// Stub fragment shader: a valid main that writes nothing visible. Pairs with
// stub.vert.glsl so a switched-off pipeline still creates and draws nothing.
// Location 0 is required for a user output under SPIR-V.
layout(location = 0) out vec4 stubColor;

void main() {
    stubColor = vec4(0.0);
}