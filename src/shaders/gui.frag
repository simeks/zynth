#version 450
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_nonuniform_qualifier : require

#include "bindless.h"
#include "gui.h"

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant, scalar) uniform _pc {
    ShaderInput pc;
};

void main() {
    float coverage = texture(
            sampler2D(texture2D_table[pc.tex], sampler_table[pc.smplr]),
            in_uv
        ).r;
    vec4 base_color = vec4(in_color.rgb, in_color.a);
    out_color = vec4(base_color.rgb * coverage, base_color.a * coverage);
}
