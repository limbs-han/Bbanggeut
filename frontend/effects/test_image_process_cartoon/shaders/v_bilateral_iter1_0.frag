#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tfm);

BNB_DECLARE_SAMPLER_2D(2, 3, texture_h_bilateral_iter1);

void main() 
{
   const float inv_two_sigma_r2 = 1.0 / 2.0 / 0.0425 / 0.0425;
   const float inv_two_sigma_d2 = 2.0 * 3.0 * 3.0;

    vec2 uv = v_tex_coord;
    vec2 textire_size = vec2(textureSize(BNB_SAMPLER_2D(texture_tfm), 0));

    vec2 t = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_tfm), uv).xy;
    vec2 dir = vec2(t.y, -t.x);
    vec2 dabs = abs(dir);
    float ds = 1.0 / ((dabs.x > dabs.y)? dabs.x : dabs.y);
    dir /= textire_size;

    vec3 center = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_h_bilateral_iter1), uv).rgb;
    vec3 sum = center;
    float norm = 1.0;
    const float half_width = 9.0;
    for (float d = ds; d <= half_width; d += ds) {
        vec3 c0 = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_h_bilateral_iter1), d * dir + uv).rgb;
        vec3 c1 = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_h_bilateral_iter1), d * dir - uv).rgb;
        float e0 = length(c0 - center);
        float e1 = length(c1 - center);

        float kerneld = exp(-d * d * inv_two_sigma_d2);
        float kernele0 = exp(-e0 * e0 * inv_two_sigma_r2);
        float kernele1 = exp(-e1 * e1 * inv_two_sigma_r2);

        float tmp0 = kernele0 * kerneld;
        float tmp1 = kernele1 * kerneld;
        norm += tmp0;
        norm += tmp1;

        sum += tmp0 * c0;
        sum += tmp1 * c1;
    }
    sum /= norm;
    bnb_FragColor = vec4(sum, 1.0);
}
