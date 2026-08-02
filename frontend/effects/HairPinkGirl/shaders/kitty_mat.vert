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


BNB_LAYOUT_LOCATION(0) BNB_IN vec3 attrib_pos;
BNB_LAYOUT_LOCATION(3) BNB_IN vec2 attrib_uv;
#ifndef BNB_GL_ES_1
BNB_LAYOUT_LOCATION(4) BNB_IN uvec4 attrib_bones;
#else
BNB_LAYOUT_LOCATION(4) BNB_IN vec4 attrib_bones;
#endif



BNB_DECLARE_SAMPLER_2D(2, 3, bnb_BONES);

BNB_OUT(0) vec2 var_uv;


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
void main()
{
	mat4 m = bnb_get_bone( 
#ifdef BNB_GL_ES_1
(float(attrib_bones[0]) * 3. + 0.5) * (1. / (bnb_ANIM.z * 3.)), 1. / (bnb_ANIM.z * 3.), (bnb_ANIM.x + 0.5) / bnb_ANIM.y
#else
attrib_bones[0], int(bnb_ANIMKEY)
#endif
 );

	vec3 vpos = attrib_pos;

	vec3 eye = -bnb_MV[3].xyz;
	vec3 pivot = vec3(m[0].w,m[1].w,m[2].w);

	mat3 billboard_rotation = shortest_arc_m3( 
		vec3(0.,0.,1.), 
		normalize(eye-pivot)*mat3(bnb_MV) );
	vpos = vec3(vec4(billboard_rotation*vpos,1.)*m);

	gl_Position = bnb_MVP * vec4(vpos,1.);

	
#ifndef BNB_VK_1
gl_Position.z = -1.;
#else
gl_Position.z = 0.;
#endif


	var_uv = attrib_uv;
}
