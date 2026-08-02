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
BNB_LAYOUT_LOCATION(4) BNB_IN uvec4 attrib_bones;
BNB_LAYOUT_LOCATION(5) BNB_IN vec4 attrib_weights;

BNB_OUT(0) vec4 var_of;
BNB_OUT(1) vec3 var_pos;

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

void main()
{
	float[] radiuses = float[]( u_hair.x, u_hair.y );
	float angle_strength = attrib_uv.x;
	float strength = u_hair.w*angle_strength;

	vec2 v = attrib_pos.xy;
	
	int ring = int(attrib_pos.z);

	mat4 glfx_MV = bnb_MV;
	mat4 glfx_MVP = bnb_MVP;

	vec3 eye = -glfx_MV[3].xyz;
	vec3 pivot = vec3(0.,50.,0.);

	mat3 billboard_rotation = shortest_arc_m3( 
		vec3(0.,0.,1.), 
		normalize(eye-pivot)*mat3(glfx_MV) );
	vec4 vpos = glfx_MVP * vec4( billboard_rotation*vec3(v*radiuses[ring],0.) + pivot, 1. );

	vec4 v0 = glfx_MVP * vec4( billboard_rotation*vec3(v*radiuses[0],0.) + pivot, 1. );
	vec4 v1 = glfx_MVP * vec4( billboard_rotation*vec3(v*(radiuses[0]+50.),0.) + pivot, 1. );

	gl_Position = vpos;

	var_of = vec4( (v1.xy/v1.w-v0.xy/v0.w)*strength, float(ring), u_hair.z );
	var_pos = gl_Position.xyw;
}