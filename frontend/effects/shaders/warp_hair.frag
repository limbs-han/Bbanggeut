#include <bnb/glsl.frag>

precision mediump float;

BNB_IN(0) vec4 var_of;
BNB_IN(1) vec3 var_pos;

BNB_DECLARE_SAMPLER_2D(0, 1, tex_frame);

float magnitude( float x, float q )
{
	return x < q ? x/q : 1.-(x-q)/(1.-q);
}

void main()
{
	vec2 o = var_of.xy*magnitude(var_of.z,var_of.w);
	vec2 uv = (var_pos.xy/var_pos.z)*0.5 + 0.5 + o;
	#ifdef BNB_VK_1
		uv.y = 1. - uv.y;
	#endif
	bnb_FragColor = texture(BNB_SAMPLER_2D(tex_frame), uv);
}