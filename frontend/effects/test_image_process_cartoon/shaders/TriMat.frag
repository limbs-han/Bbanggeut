#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(18, 19, glfx_BACKGROUND);


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tensor);

BNB_DECLARE_SAMPLER_2D(2, 3, texture_lab);

BNB_DECLARE_SAMPLER_2D(4, 5, texture_tfm);

BNB_DECLARE_SAMPLER_2D(6, 7, texture_tfm_horizontal);

BNB_DECLARE_SAMPLER_2D(8, 9, texture_final_rgb);

BNB_DECLARE_SAMPLER_2D(10, 11, texture_fdog_v);




BNB_DECLARE_SAMPLER_2D(12, 13, texture_quantization);

BNB_DECLARE_SAMPLER_2D(14, 15, texture_v_bilateral_iter1);

BNB_DECLARE_SAMPLER_2D(16, 17, texture_smaller_frame);


void main()
{
    vec2 uv = v_tex_coord;

    vec3 c = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_final_rgb), uv).xyz;
    float e = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_fdog_v), uv).x;

    bnb_FragColor = vec4(c - e, 1.0);
}
