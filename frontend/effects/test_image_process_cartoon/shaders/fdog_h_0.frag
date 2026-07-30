#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tfm);

BNB_DECLARE_SAMPLER_2D(2, 3, texture_v_bilateral_iter1);

void main() 
{
    const float sigma_e = 1.0;
    float sigma_r = 1.6 * sigma_e;
    sigma_r = 5.0;
    float tau = 0.97;

    float two_sigma_e_squared = 2.0 * sigma_e * sigma_e;
    float two_sigma_r_squared = 2.0 * sigma_r * sigma_r;

    vec2 uv = v_tex_coord;
    vec2 textire_size = vec2(textureSize(BNB_SAMPLER_2D(texture_v_bilateral_iter1), 0));

    vec2 n = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tfm), uv).xy;
    vec2 nabs = abs(n);
    float ds = 1.0 / ((nabs.x > nabs.y) ? nabs.x : nabs.y);
    n /= textire_size;

    vec2 sum = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_v_bilateral_iter1), uv).xx;
    vec2 norm = vec2(1.0, 1.0);

    float half_width = 10.0;
    for (float d = ds; d <= half_width; d += ds) {
        vec2 kernel = vec2(exp(-d * d / two_sigma_e_squared), 
                           exp(-d * d / two_sigma_r_squared));

        norm += 2.0 * kernel;

        vec2 L0 = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_v_bilateral_iter1), uv - d * n).xx;
        vec2 L1 = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_v_bilateral_iter1), uv + d * n).xx;
        
        sum += kernel * (L0 + L1);
    }

    sum /= norm;

    float diff = 100.0 * (sum.x - tau * sum.y);

    bnb_FragColor = vec4(diff, 0.0, 0.0, 1.0);
}
