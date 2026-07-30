#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, glfx_BACKGROUND);

void main()
{
    vec2 uv = v_tex_coord;
    bnb_FragColor = BNB_TEXTURE_2D(BNB_SAMPLER_2D(glfx_BACKGROUND), uv);
}