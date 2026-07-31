#include <bnb/glsl.frag>
#define REFL_SCALE_X 0.35
#define REFL_SCALE_Y 0.5
#define REFL_X -0.9
#define REFL_Y -2.1
//#define BNB_USE_SHADOW

#define GLFX_TBN
//#define GLFX_DIELECTRIC
//#define GLFX_TEX_MRAO
//#define GLFX_AO
//#define GLFX_TEX_EMI
//#define GLFX_NORMAL_DIRECTX
//#define GLFX_2SIDED
#define GLFX_IBL
//#define GLFX_LIGHTS
BNB_IN(0) vec2 var_uv;
#ifdef GLFX_TBN
BNB_IN(1) vec3 var_t;
BNB_IN(2) vec3 var_b;
#endif
BNB_IN(3) vec3 var_n;
BNB_IN(4) vec3 var_v;

BNB_DECLARE_SAMPLER_2D(0, 1, tex_diffuse);
#ifdef GLFX_TBN

BNB_DECLARE_SAMPLER_2D(2, 3, tex_normal);
#endif
#ifdef GLFX_TEX_MRAO
#else

BNB_DECLARE_SAMPLER_2D(4, 5, tex_metallic);

BNB_DECLARE_SAMPLER_2D(6, 7, tex_roughness);
#ifdef GLFX_AO
#endif
#endif
#ifdef GLFX_TEX_EMI
#endif

BNB_DECLARE_SAMPLER_2D(14, 15, tex_refl);
#ifdef BNB_USE_SHADOW

BNB_IN(5) vec3 var_shadow_coord;
float glfx_shadow_factor()
{

	vec2 offsets[4];
	offsets[0] = vec2( -0.94201624, -0.39906216 );
	offsets[1] = vec2( 0.94558609, -0.76890725 );
	offsets[2] = vec2( -0.094184101, -0.92938870 );
	offsets[3] = vec2( 0.34495938, 0.29387760 );
    float s = 0.;
    for( int i = 0; i != 4 /*assume that offsets.length() was called.*/; ++i )
        s += texture( glfx_SHADOW, var_shadow_coord + vec3(offsets[i]/110.,0.1) );
    s *= 0.125;
    return s;
}
#endif
// gamma to linear
vec3 g2l( vec3 g )
{
    return g*(g*(g*0.305306011+0.682171111)+0.012522878);
}
// linear to gamma
vec3 l2g( vec3 l )
{
    vec3 s = sqrt(l);
    vec3 q = sqrt(s);
    return 0.662002687*s + 0.68412206*q - 0.323583601*sqrt(q) - 0.022541147*l;
}
vec3 fresnel_schlick( float prod, vec3 F0 )
{
    return F0 + ( 1. - F0 )*pow( 1. - prod, 5. );
}
vec3 fresnel_schlick_roughness( float prod, vec3 F0, float roughness )
{
    return F0 + ( max( F0, 1. - roughness ) - F0 )*pow( 1. - prod, 5. );
}
float distribution_GGX( float cN_H, float roughness )
{
    float a = roughness*roughness;
    float a2 = a*a;
    float d = cN_H*cN_H*( a2 - 1. ) + 1.;
    return a2/(3.14159265*d*d);
}
float geometry_schlick_GGX( float NV, float roughness )
{
    float r = roughness + 1.;
    float k = r*r/8.;
    return NV/( NV*( 1. - k ) + k );
}
float geometry_smith( float cN_L, float ggx2, float roughness )
{
    return geometry_schlick_GGX( cN_L, roughness )*ggx2;
}
float diffuse_factor( float n_l, float w )
{
    float w1 = 1. + w;
    return pow( max( 0., n_l + w )/w1, w1 );
}
#ifdef GLFX_IBL

BNB_DECLARE_SAMPLER_2D(8, 9, tex_brdf);

BNB_DECLARE_SAMPLER_CUBE(10, 11, tex_ibl_diff);

BNB_DECLARE_SAMPLER_CUBE(12, 13, tex_ibl_spec);
#endif
#ifdef GLFX_LIGHTS
// direction in xyz, lwrap in w
#endif
vec2 latlon( vec3 d )
{
    d.xz = d.zx;
    float theta = acos( d.y );
    float phi = atan( d.z, d.x ) + 3.1415926;
    return vec2( phi, theta )*vec2( 0.1591549/REFL_SCALE_X, 0.6366198/REFL_SCALE_Y ) + vec2(REFL_X,REFL_Y);
}
void main()
{
#ifdef GLFX_LIGHTS
	vec3 radiance[2];
	radiance[1] = vec3(1.,1.,1.)*0.9*2.;
	radiance[0] = vec3(1.,1.,1.)*2.;
#endif
#ifdef GLFX_LIGHTS
	vec4 lights[2];
	lights[1] = vec4(normalize(vec3(97.6166,-48.185,183.151)),1.);
	lights[0] = vec4(0.,0.6,0.8,1.);
#endif
    vec4 base_opacity = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_diffuse),var_uv);
    //if( base_opacity.w < 0.5 ) discard;
    vec3 base = g2l(base_opacity.xyz);
    float opacity = base_opacity.w;
#ifdef GLFX_TEX_MRAO
    vec3 mrao = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_mrao),var_uv).xyz;
    float metallic = mrao.x;
    float roughness = mrao.y;
#else
#ifdef GLFX_DIELECTRIC
    float metallic = 0.;
#else
    float metallic = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_metallic),var_uv).x;
#endif
    float roughness = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_roughness),var_uv).x;
#endif
#ifdef GLFX_TBN
#ifdef GLFX_NORMAL_DIRECTX
    vec3 N = normalize( mat3(var_t,var_b,var_n)*(BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_normal),var_uv).xyz*vec3(2.,-2.,2.)-vec3(1.,-1.,1.)) );
#else
    vec3 N = normalize( mat3(var_t,var_b,var_n)*(BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_normal),var_uv).xyz*2.-1.) );
#endif
#else
    vec3 N = normalize( var_n );
#endif
#ifdef GLFX_2SIDED
    N *= gl_FrontFacing ? 1. : -1.;
#endif
    
    mat3 matr = mat3 (0.7, 0.0, -0.7,
                      0.0, 1.0, 0.0,
                      0.7, 0.0, 0.70);
    
  /*  mat3 matr = mat3 (0.96, 0.0, 0.25,
                      0.0, 1.0, 0.0,
                      -0.2, 0.0, 0.96);*/
    vec3 V = normalize( -var_v );
    float cN_V = max( 0., dot( N, V ) );
    vec3 R = reflect( -V, -N * matr);
    vec3 F0 = mix( vec3(0.04), base, metallic );
    vec3 F = fresnel_schlick_roughness( cN_V, F0, roughness );
    vec3 kD = ( 1. - F )*( 1. - metallic );   
    
    vec3 diffuse = BNB_TEXTURE_CUBE(BNB_SAMPLER_CUBE(tex_ibl_diff), N ).xyz * base;
    
    const float MAX_REFLECTION_LOD = 7.;    // number of mip levels in tex_ibl_spec
    vec3 prefilteredColor = BNB_TEXTURE_CUBE_LOD(BNB_SAMPLER_CUBE(tex_ibl_spec), R, roughness*MAX_REFLECTION_LOD ).xyz;
    //vec2 brdf = BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_brdf), vec2( cN_V, roughness ) ).yx;
    //vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);
    vec3 color = (kD*diffuse /*+ specular*/);
    //color *= 2.5; 
    vec3 refl_v = clamp( reflect( -V, N ), -1., 1. );
    vec2 refl_uv = latlon( refl_v );

    refl_uv.x += 0.5;
    refl_uv.x *= 0.45;

    refl_uv.y += 1.3;
    refl_uv.y *=  0.45;

    vec3 refl = 2.0*BNB_TEXTURE_2D(BNB_SAMPLER_2D(tex_refl), refl_uv ).xyz*(1.-roughness);
    bnb_FragColor = vec4(l2g(color) +refl * F * 0.5 ,pow(opacity,1.0)*1.4);
    bnb_FragColor *=1.0;
}
