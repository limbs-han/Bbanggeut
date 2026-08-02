#include <bnb/glsl.frag>

#ifndef BNB_GL_ES_1

precision mediump float;
precision mediump sampler2DArray;
precision mediump sampler2DShadow;

#endif /* BNB_GL_ES_1 */

BNB_IN(0) vec2 var_uv;
BNB_IN(1) vec3 var_t;
BNB_IN(2) vec3 var_b;
BNB_IN(3) vec3 var_n;
BNB_IN(4) vec3 var_v;

BNB_DECLARE_SAMPLER_2D(0, 1, tex_diffuse);
BNB_DECLARE_SAMPLER_2D(2, 3, tex_normal);
BNB_DECLARE_SAMPLER_2D(4, 5, tex_mrao);
BNB_DECLARE_SAMPLER_2D(6, 7, tex_brdf);

BNB_DECLARE_SAMPLER_CUBE(8, 9, tex_ibl_diff);
BNB_DECLARE_SAMPLER_CUBE(10, 11, tex_ibl_spec);

// gamma to linear
vec3 g2l( vec3 g )
{
    return g*(g*(g*0.305306011+0.682171111)+0.012522878);
}

// combined hdr to ldr and linear to gamma
vec3 l2g( vec3 l )
{
    return sqrt(1.33*(1.-exp(-l)))-0.03;
}

vec3 fresnel_schlick_roughness( float prod, vec3 F0, float roughness )
{
    return F0 + ( max( F0, 1. - roughness ) - F0 )*pow( 1. - prod, 5. );
}

void main()
{
    vec4 base_opacity = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_diffuse),var_uv);

    vec3 base = g2l(base_opacity.xyz);
    float opacity = base_opacity.w;

    vec3 mrao = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_mrao),var_uv).xyz;

    float metallic = mrao.x;
    float roughness = mrao.y;

    vec3 N = normalize( mat3(var_t,var_b,var_n)*(BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_normal),var_uv).xyz*2.-1.) );

    vec3 V = normalize( -var_v );
    float cN_V = max( 0., dot( N, V ) );
    vec3 R = reflect( -V, N );

    vec3 F0 = mix( vec3(0.04), base, metallic );

    vec3 F = fresnel_schlick_roughness( cN_V, F0, roughness );
    vec3 kD = ( 1. - F )*( 1. - metallic );

    vec3 diffuse = BNB_TEXTURE_CUBE( BNB_SAMPLER_CUBE(tex_ibl_diff), N ).xyz * base;

    const float MAX_REFLECTION_LOD = 7.; // number of mip levels in tex_ibl_spec
    vec3 prefilteredColor = BNB_TEXTURE_CUBE_LOD( BNB_SAMPLER_CUBE(tex_ibl_spec), R, roughness*MAX_REFLECTION_LOD ).xyz;
    vec2 brdf = BNB_TEXTURE_2D( BNB_SAMPLER_2D(tex_brdf), vec2( cN_V, roughness ) ).yx;
    vec3 specular = prefilteredColor * (F0 * brdf.x + brdf.y);

    vec3 color = (kD*diffuse + specular);

    bnb_FragColor = vec4(l2g(color),opacity);
}
