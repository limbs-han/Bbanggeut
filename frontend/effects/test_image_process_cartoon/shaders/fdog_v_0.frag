#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_tfm);

BNB_DECLARE_SAMPLER_2D(2, 3, texture_fdog_h);

struct lic_t 
{ 
    vec2 p; 
    vec2 t;
    float w;
    float dw;
};

void step1(inout lic_t s) 
{
    vec2 t = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(texture_tfm), s.p, 0.).xy;
    t = vec2(t.y, -t.x);

    t *= sign(dot(t, s.t));
    
    s.t = t;

    s.dw = (abs(t.x) > abs(t.y)) 
            ? abs((fract(s.p.x) - 0.5 - sign(t.x)) / t.x) 
            : abs((fract(s.p.y) - 0.5 - sign(t.y)) / t.y);

    vec2 textire_size_inv = 1.0 / vec2(textureSize(BNB_SAMPLER_2D(texture_fdog_h), 0));
    s.p += t * s.dw * textire_size_inv;
    s.w += s.dw;
}

void main() 
{
    float sigma_m = 2.0;
    float phi = 3.5;
    float two_sigma_m_squared = 2.0 * sigma_m * sigma_m;
    float half_width = 5.0 * sigma_m;

    vec2 uv = v_tex_coord;
    vec2 textire_size = vec2(textureSize(BNB_SAMPLER_2D(texture_fdog_h), 0));

    float H = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(texture_fdog_h), uv, 0.).x;
    float w = 1.0;

    lic_t a, b;
    a.p = b.p = uv;
    vec2 t = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(texture_tfm), uv, 0.).xy;
    t = vec2(t.y, -t.x);
    a.t =  t / textire_size;
    b.t = -a.t;
    a.w = b.w = 0.0;

    while (a.w < half_width) {
        step1(a);
        float k = a.dw * exp(-a.w * a.w / two_sigma_m_squared);
        H += k * BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(texture_fdog_h), a.p, 0.).x;
        w += k;
    }

    while (b.w < half_width) {
        step1(b);
        float k = b.dw * exp(-b.w * b.w / two_sigma_m_squared);
        H += k * BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(texture_fdog_h), b.p, 0.).x;
        w += k;
    }

    H /= w;

    float edge = (H > 0.0) ? 0.0 : 1.0;
    bnb_FragColor = vec4(edge, 1.0, 1.0, 1.0);
}
