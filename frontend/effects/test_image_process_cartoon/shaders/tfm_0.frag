#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tfm_horizontal);

void main() 
{
    vec2 uv = v_tex_coord;
    vec2 texture_size = vec2(textureSize(BNB_SAMPLER_2D(texture_tfm_horizontal), 0));
    vec2 d = vec2(1.0) / texture_size;

    const int kernel_size = 14;
    const float norm_factor = 16.8769 * 16.8769;
    const float center_weight = 1.0;
    const float gauss_weights[kernel_size] = float[kernel_size](
        0.989848, 0.960005, 0.912254, 0.849366, 0.774837, 
        0.692569, 0.606531, 0.52045, 0.437565, 0.360448, 
        0.290924, 0.230066, 0.178264, 0.135335);

    vec3 g = center_weight * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tfm_horizontal), uv).rgb;

    for (int i = 1; i <= kernel_size; ++i) {
        g += gauss_weights[i - 1] * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tfm_horizontal), uv + vec2(0.0,  float(i) * d.y)).rgb;
        g += gauss_weights[i - 1] * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tfm_horizontal), uv + vec2(0.0, -float(i) * d.y)).rgb;
    }

    g = g / norm_factor;
    float tmp = g.x - g.z;
    tmp *= tmp;
    vec2 v1 = vec2(g.y, 0.5 * (g.z - g.x + sqrt(4.0 * g.y * g.y + tmp)));

    bnb_FragColor = length(v1) > 0.0 ? vec4(normalize(v1), 0.0, 1.0) : vec4(0.0, 1.0, 0.0, 1.0);
}
