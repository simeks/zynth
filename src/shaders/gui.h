#ifndef GUI_GLSL
#define GUI_GLSL

struct Vertex {
    vec4 pos;
    vec4 color;
    vec2 uv;
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer IndexBuffer {
    uint index[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer VertexBuffer {
    Vertex vertex[];
};

struct ShaderInput {
    VertexBuffer vbuf;
    IndexBuffer ibuf;
    uint tex;
    uint smplr;
};

#endif // GUI_GLSL
