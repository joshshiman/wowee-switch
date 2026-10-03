#version 450

// Stub vertex shader: a valid main that emits a degenerate position. Used when
// a pipeline's real shader is switched off, so the pipeline still creates and
// the draw contributes nothing. No inputs, no outputs beyond gl_Position.
void main() {
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
}