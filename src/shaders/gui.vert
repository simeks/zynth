#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_nonuniform_qualifier : require

#include "gui.h"

layout(push_constant, scalar) uniform _pc {
    ShaderInput pc;
};

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;

void main() {
    uint index_offset = uint(gl_VertexIndex);
    uint vertex_index = pc.ibuf.index[index_offset];
    Vertex vtx = pc.vbuf.vertex[vertex_index];
    gl_Position = vec4(vtx.pos.x, vtx.pos.y, 0.0f, 1.0f);
    out_color = vtx.color;
    out_uv = vtx.uv;
}
