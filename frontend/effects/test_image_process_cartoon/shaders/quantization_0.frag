#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;




BNB_DECLARE_SAMPLER_2D(0, 1, texture_v_bilateral_iter1);

void main() 
{
    vec2 uv = v_tex_coord;
    vec3 c = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_v_bilateral_iter1), uv).rgb;

    int nbins = 8;
    float phi_q = 1.0;

    float qn = floor(c.x * float(nbins) + 0.5) / float(nbins);
    float qs = smoothstep(-1.5, 1.5, phi_q * (c.x - qn) * 100.0) - 0.5;
    float qc = qn + qs / float(nbins);

    bnb_FragColor = vec4(vec3(qc, c.yz), 1.0);
}
