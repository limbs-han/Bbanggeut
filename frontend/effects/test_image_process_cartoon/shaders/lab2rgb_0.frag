#include <bnb/glsl.frag>


BNB_IN(0) vec2 v_tex_coord;


BNB_DECLARE_SAMPLER_2D(0, 1, texture_quantization);

vec3 lab2xyz(vec3 c) 
{
    float fy = (c.x + 16.0) / 116.0;
    float fx = c.y / 500.0 + fy;
    float fz = fy - c.z / 200.0;
    
    return vec3(
         95.047 * ((fx > 0.206897) ? fx * fx * fx : (fx - 16.0 / 116.0) / 7.787),
        100.000 * ((fy > 0.206897) ? fy * fy * fy : (fy - 16.0 / 116.0) / 7.787),
        108.883 * ((fz > 0.206897) ? fz * fz * fz : (fz - 16.0 / 116.0) / 7.787)
    );
}

vec3 xyz2rgb( vec3 c ) 
{
    vec3 v = c / 100.0 * mat3( 
        3.2406, -1.5372, -0.4986,
        -0.9689, 1.8758, 0.0415,
        0.0557, -0.2040, 1.0570
    );

    vec3 r;
    r.x = ( v.r > 0.0031308 ) ? (( 1.055 * pow( v.r, ( 1.0 / 2.4 ))) - 0.055 ) : 12.92 * v.r;
    r.y = ( v.g > 0.0031308 ) ? (( 1.055 * pow( v.g, ( 1.0 / 2.4 ))) - 0.055 ) : 12.92 * v.g;
    r.z = ( v.b > 0.0031308 ) ? (( 1.055 * pow( v.b, ( 1.0 / 2.4 ))) - 0.055 ) : 12.92 * v.b;

    return r;
}

vec3 lab2rgb(vec3 c) 
{
    return xyz2rgb(lab2xyz(vec3(100.0 * c.x, 2.0 * 127.0 * (c.y - 0.5), 2.0 * 127.0 * (c.z - 0.5))));
}

void main() 
{
    vec2 uv = v_tex_coord;
    vec3 color = BNB_TEXTURE_2D(BNB_SAMPLER_2D(texture_quantization), uv).rgb;

    bnb_FragColor = vec4(clamp(lab2rgb(clamp(color, 0.0, 1.0)), 0.0, 1.0), 1.0);
}