#include <bnb/glsl.vert>

BNB_LAYOUT_LOCATION(0) BNB_IN vec3 attrib_pos;

#ifdef BNB_VK_1
BNB_LAYOUT_LOCATION(1) BNB_IN uint attrib_n;
BNB_LAYOUT_LOCATION(2) BNB_IN uint attrib_t;
#else
BNB_LAYOUT_LOCATION(1) BNB_IN vec4 attrib_n;
BNB_LAYOUT_LOCATION(2) BNB_IN vec4 attrib_t;
#endif

BNB_LAYOUT_LOCATION(3) BNB_IN vec2 attrib_uv;

#ifndef BNB_GL_ES_1
BNB_LAYOUT_LOCATION(4) BNB_IN uvec4 attrib_bones;
#else
BNB_LAYOUT_LOCATION(4) BNB_IN vec4 attrib_bones;
#endif
BNB_LAYOUT_LOCATION(5) BNB_IN vec4 attrib_weights;

BNB_DECLARE_SAMPLER_2D(12, 13, bnb_BONES);

BNB_OUT(0) vec2 var_uv;
BNB_OUT(1) vec3 var_t;
BNB_OUT(2) vec3 var_b;
BNB_OUT(3) vec3 var_n;
BNB_OUT(4) vec3 var_v;


#include <bnb/decode_int1010102.glsl>
#include <bnb/anim_transform.glsl>

void main()
{
    mat4 m = bnb_get_transform();
    vec3 vpos = (vec4(attrib_pos,1.) * m).xyz;

    gl_Position = bnb_MVP * vec4(vpos,1.);

    var_uv = attrib_uv;

    mat3 mv0_3 = mat3(bnb_MV[0].xyz,bnb_MV[1].xyz,bnb_MV[2].xyz);
    mat3 m_3 = mat3(m[0].xyz,m[1].xyz,m[2].xyz);

    vec4 attrib_t1 = decode_int1010102(attrib_t);
    vec4 attrib_n1 = decode_int1010102(attrib_n);

    var_t = normalize(mv0_3*(attrib_t1.xyz*m_3));
    var_n = normalize(mv0_3*(attrib_n1.xyz*m_3));
    var_b = attrib_t1.w * cross( var_n, var_t );
    var_v = vec3(bnb_MV * vec4(vpos,1.));
}