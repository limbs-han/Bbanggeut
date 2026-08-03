#include <bnb/glsl.vert>
#include <bnb/decode_int1010102.glsl>
#include<bnb/matrix_operations.glsl>
#define bnb_IDX_OFFSET 0
#ifdef BNB_VK_1
#ifdef gl_VertexID
#undef gl_VertexID
#endif
#ifdef gl_InstanceID
#undef gl_InstanceID
#endif
#define gl_VertexID gl_VertexIndex
#define gl_InstanceID gl_InstanceIndex
#endif


#define BNB_USE_UVMORPH

BNB_LAYOUT_LOCATION(0) BNB_IN vec3 attrib_pos;
#ifdef GLFX_LIGHTING
#ifdef BNB_VK_1
BNB_LAYOUT_LOCATION(1) BNB_IN uint attrib_n;
#else
BNB_LAYOUT_LOCATION(1) BNB_IN vec4 attrib_n;
#endif
#ifdef GLFX_TBN
#ifdef BNB_VK_1
BNB_LAYOUT_LOCATION(2) BNB_IN uint attrib_t;
#else
BNB_LAYOUT_LOCATION(2) BNB_IN vec4 attrib_t;
#endif
#endif
#endif
BNB_LAYOUT_LOCATION(3) BNB_IN vec2 attrib_uv;
#ifndef BNB_GL_ES_1
BNB_LAYOUT_LOCATION(4) BNB_IN uvec4 attrib_bones;
#else
BNB_LAYOUT_LOCATION(4) BNB_IN vec4 attrib_bones;
#endif
#ifndef BNB_1_BONE
BNB_LAYOUT_LOCATION(5) BNB_IN vec4 attrib_weights;
#endif



BNB_DECLARE_SAMPLER_2D(2, 3, bnb_BONES);

#ifdef BNB_USE_UVMORPH

BNB_DECLARE_SAMPLER_2D(4, 5, bnb_UVMORPH);
#ifdef GLFX_USE_BG

BNB_DECLARE_SAMPLER_2D(6, 7, bnb_STATICPOS);
#endif
#endif

#ifdef GLFX_USE_BG
BNB_OUT(1) vec2 var_bg_uv;
#endif

#ifdef BNB_USE_AUTOMORPH

BNB_DECLARE_SAMPLER_2D(8, 9, bnb_MORPH);
#ifndef BNB_AUTOMORPH_BONE
#else
#endif
#endif

BNB_OUT(0) vec2 var_uv;
#ifdef GLFX_LIGHTING
#ifdef GLFX_TBN
BNB_OUT(2) vec3 var_t;
BNB_OUT(3) vec3 var_b;
#endif
BNB_OUT(4) vec3 var_n;
BNB_OUT(5) vec3 var_v;
#endif

#ifdef BNB_USE_SHADOW

BNB_OUT(6) vec3 var_shadow_coord;
vec3 spherical_proj( vec2 fovM, vec2 fovP, float zn, float zf, vec3 v )
{
    vec2 xy = (atan( v.xy, v.zz )-(fovP+fovM)*0.5)/((fovP-fovM)*0.5);
    float z = (length(v)-(zn+zf)*0.5)/((zf-zn)*0.5);
    return vec3( xy, z );
}
#endif


mat3 shortest_arc_m3( vec3 from, vec3 to )
{
    vec3 a = cross( from, to );
    float c = dot( from, to );

    float t = 1./(1.+c);
    float tx = t*a.x;
    float ty = t*a.y;
    float tz = t*a.z;
    float txy = tx*a.y;
    float txz = tx*a.z;
    float tyz = ty*a.z;

    return mat3
    (
        c + tx*a.x, txy + a.z, txz - a.y,
        txy - a.z, c + ty*a.y, tyz + a.x,
        txz + a.y, tyz - a.x, c + tz*a.z
    );
}

#include <bnb/get_bone.glsl>
#include <bnb/morph_transform.glsl>
void main()
{
    mat4 m = bnb_get_bone( 
#ifdef BNB_GL_ES_1
(float(attrib_bones[0]) * 3. + 0.5) * (1. / (bnb_ANIM.z * 3.)), 1. / (bnb_ANIM.z * 3.), bnb_ANIMKEY
#else
attrib_bones[0], int(bnb_ANIMKEY)
#endif
 );
#ifndef BNB_1_BONE
    if( attrib_weights[1] > 0. )
    {
        m = m*attrib_weights[0] + bnb_get_bone( 
#ifdef BNB_GL_ES_1
(float(attrib_bones[1]) * 3. + 0.5) * (1. / (bnb_ANIM.z * 3.)), 1. / (bnb_ANIM.z * 3.), bnb_ANIMKEY
#else
attrib_bones[1], int(bnb_ANIMKEY)
#endif
 )*attrib_weights[1];
        if( attrib_weights[2] > 0. )
        {
            m += bnb_get_bone( 
#ifdef BNB_GL_ES_1
(float(attrib_bones[2]) * 3. + 0.5) * (1. / (bnb_ANIM.z * 3.)), 1. / (bnb_ANIM.z * 3.), bnb_ANIMKEY
#else
attrib_bones[2], int(bnb_ANIMKEY)
#endif
 )*attrib_weights[2];
            if( attrib_weights[3] > 0. )
                m += bnb_get_bone( 
#ifdef BNB_GL_ES_1
(float(attrib_bones[3]) * 3. + 0.5) * (1. / (bnb_ANIM.z * 3.)), 1. / (bnb_ANIM.z * 3.), bnb_ANIMKEY
#else
attrib_bones[3], int(bnb_ANIMKEY)
#endif
 )*attrib_weights[3];
        }
    }
#endif

    vec3 vpos = attrib_pos;
    vpos = vec3(vec4(vpos,1.)*m);

    vec3 eye = -bnb_MV[3].xyz;
    vec3 pivot = vec3(-87.5,-13.,188.5);

    mat3 billboard_rotation = shortest_arc_m3( 
        vec3(0.,0.,1.), 
        normalize(eye-pivot)*mat3(bnb_MV) );
    vpos = billboard_rotation*(vpos-pivot) + pivot;

#ifdef BNB_USE_UVMORPH
    vec2 flip_uv = vec2( 0.55, 0.33 );
    vec3 translation = BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_UVMORPH),flip_uv).xyz;
    vpos += translation;
#endif


    gl_Position = bnb_MVP * vec4(vpos,1.);

    var_uv = attrib_uv;
}
