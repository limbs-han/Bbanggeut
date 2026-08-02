#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tensor);

void main() 
{
    vec2 uv = v_tex_coord;
    vec2 texture_size = vec2(textureSize(BNB_SAMPLER_2D(texture_tensor), 0));
    vec2 d = 1.0 / texture_size;

    // const float norm_factor = 16.8769;
    const int kernel_size = 14;
    const float center_weight = 1.0;
    const float gauss_weights[kernel_size] = float[kernel_size](
        0.989848, 0.960005, 0.912254, 0.849366, 0.774837, 
        0.692569, 0.606531, 0.52045, 0.437565, 0.360448, 
        0.290924, 0.230066, 0.178264, 0.135335);


    vec3 result = center_weight * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tensor), uv).rgb;

    for (int i = 1; i <= kernel_size; ++i) {
        result += gauss_weights[i - 1] * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tensor), uv + vec2( float(i) * d.x, 0.0)).rgb;
        result += gauss_weights[i - 1] * BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tensor), uv + vec2(-float(i) * d.x, 0.0)).rgb;
    }

    bnb_FragColor = vec4(result, 1.0);
}
