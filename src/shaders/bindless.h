#ifndef BINDLESS_GLSL
#define BINDLESS_GLSL

#define BINDLESS_SAMPLED_TEXTURES 0
#define BINDLESS_STORAGE_TEXTURES 1
#define BINDLESS_SAMPLERS 2

layout(binding = BINDLESS_SAMPLED_TEXTURES, set = 0) uniform texture2D texture2D_table[];
layout(binding = BINDLESS_SAMPLED_TEXTURES, set = 0) uniform utexture2D utexture2D_table[];

layout(binding = BINDLESS_STORAGE_TEXTURES, set = 0) uniform writeonly image2D image2D_wo_table[];
layout(binding = BINDLESS_STORAGE_TEXTURES, set = 0) uniform writeonly uimage2D uimage2D_wo_table[];

layout(binding = BINDLESS_SAMPLERS, set = 0) uniform sampler sampler_table[];

#endif // BINDLESS_GLSL
