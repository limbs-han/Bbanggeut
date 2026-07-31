#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_lab);


void main() 
{
   vec2 uv = v_tex_coord;
   vec2 textire_size = vec2(textureSize(BNB_SAMPLER_2D(texture_lab), 0));

    vec2 d = 1.0 / textire_size;

    vec4 u = (
             -1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2(-d.x, -d.y)) +
             -2.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2(-d.x,  0.0)) + 
             -1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2(-d.x,  d.y)) +
             +1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( d.x, -d.y)) +
             +2.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( d.x,  0.0)) + 
             +1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( d.x,  d.y))
             ) / 4.0;

    vec4 v = (
             -1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2(-d.x, -d.y)) + 
             -2.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( 0.0, -d.y)) + 
             -1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( d.x, -d.y)) +
             +1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2(-d.x,  d.y)) +
             +2.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( 0.0,  d.y)) + 
             +1.0 * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_lab), uv + vec2( d.x,  d.y))
             ) / 4.0;

    bnb_FragColor = vec4(vec3(dot(u.xyz, u.xyz), dot(u.xyz, v.xyz), dot(v.xyz, v.xyz)), 1.0);
}

