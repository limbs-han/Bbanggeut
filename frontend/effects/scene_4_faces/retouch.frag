#include <bnb/glsl.frag>

#define TEETH_WHITENING
#define teethWhiteningCoeff 1.0
#define EYES_WHITENING
#define eyesWhiteningCoeff 0.5
#define SOFT_SKIN
#define skinSoftIntensity 0.7
#define SHARPEN_TEETH
#define teethSharpenIntensity 0.2
#define SHARPEN_EYES
#define eyesSharpenIntensity 0.3
#define PSI 0.1
//#define TEXTURE_LOOKUP

BNB_IN(0) vec2 var_uv;
BNB_IN(1) vec2 var_bg_uv;
BNB_IN(2) vec3 maskColor;
BNB_IN(3+0) vec4 sp0;
BNB_IN(3+1) vec4 sp1;
BNB_IN(3+2) vec4 sp2;
BNB_IN(3+3) vec4 sp3;


BNB_DECLARE_SAMPLER_2D(0, 1, lookupTexEyes);
BNB_DECLARE_SAMPLER_2D(2, 3, lookupTexTeeth);
BNB_DECLARE_SAMPLER_2D(4, 5, selection_tex);
BNB_DECLARE_SAMPLER_2D(6, 7, bnb_BACKGROUND);

#ifdef TEXTURE_LOOKUP
vec4 textureLookup(vec4 originalColor, sampler2D lookupTexture)
{
    const float epsilon = 0.000001;
    const float lutSize = 512.0;

    float blueValue = (originalColor.b * 255.0) / 4.0;

    vec2 mulB = clamp(floor(blueValue) + vec2(0.0, 1.0), 0.0, 63.0);
    vec2 row = floor(mulB / 8.0 + epsilon);
    vec4 row_col = vec4(row, mulB - row * 8.0);
    vec4 lookup = originalColor.ggrr * (63.0 / lutSize) + row_col * (64.0 / lutSize) + (0.5 / lutSize);

    float factor = blueValue - mulB.x;

    vec3 sampled1 = BNB_TEXTURE_2D_LOD(lookupTexture, lookup.zx, 0.).rgb;
    vec3 sampled2 = BNB_TEXTURE_2D_LOD(lookupTexture, lookup.wy, 0.).rgb;

    vec3 res = mix(sampled1, sampled2, factor);
    return vec4(res, originalColor.a);
}
#endif

#if defined(EYES_WHITENING)
vec4 eyes_whitening(vec4 originalColor, float w_factor) {
    const float epsilon = 0.000001;
    const float lutSize = 512.0;

    float blueValue = (originalColor.b * 255.0) / 4.0;

    vec2 mulB = clamp(floor(blueValue) + vec2(0.0, 1.0), 0.0, 63.0);
    vec2 row = floor(mulB / 8.0 + epsilon);
    vec4 row_col = vec4(row, mulB - row * 8.0);
    vec4 lookup = originalColor.ggrr * (63.0 / lutSize) + row_col * (64.0 / lutSize) + (0.5 / lutSize);

    float factor = blueValue - mulB.x;

    vec3 sampled1 = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(lookupTexEyes), lookup.zx, 0.).rgb;
    vec3 sampled2 = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(lookupTexEyes), lookup.wy, 0.).rgb;

    vec4 color = vec4(mix(sampled1, sampled2, factor), originalColor.a);
    return mix(originalColor, color, w_factor);
}
#endif

#if defined(TEETH_WHITENING)
vec4 teeth_whitening(vec4 originalColor, float w_factor) {
    const float epsilon = 0.000001;
    const float lutSize = 512.0;

    float blueValue = (originalColor.b * 255.0) / 4.0;

    vec2 mulB = clamp(floor(blueValue) + vec2(0.0, 1.0), 0.0, 63.0);
    vec2 row = floor(mulB / 8.0 + epsilon);
    vec4 row_col = vec4(row, mulB - row * 8.0);
    vec4 lookup = originalColor.ggrr * (63.0 / lutSize) + row_col * (64.0 / lutSize) + (0.5 / lutSize);

    float factor = blueValue - mulB.x;

    vec3 sampled1 = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(lookupTexTeeth), lookup.zx, 0.).rgb;
    vec3 sampled2 = BNB_TEXTURE_2D_LOD(BNB_SAMPLER_2D(lookupTexTeeth), lookup.wy, 0.).rgb;

    vec4 color = vec4(mix(sampled1, sampled2, factor), originalColor.a);
    return mix(originalColor, color, w_factor);
}
#endif

vec4 sharpen(vec4 originalColor, float factor) {
    vec4 total = 5.0 * originalColor - BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp0.zw) -
    BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp1.zw) - BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp2.zw) - BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp3.zw);
    vec4 result = mix(originalColor, total, factor);
    return clamp(result, 0.0, 1.0);;
}

vec4 getLuminance4(mat4 color) {
    const vec4 rgb2y = vec4(0.299, 0.587, 0.114, 0.0);
    return rgb2y * color;
}

float getLuminance(vec4 color) {
    const vec4 rgb2y = vec4(0.299, 0.587, 0.114, 0.0);
    return max(dot(color, rgb2y), 0.00001);
}

vec4 getWeight(float intensity, vec4 nextIntensity) {
    vec4 lglg = log(nextIntensity / intensity) * log(nextIntensity / intensity);
    return exp(lglg / (-2.0 *  PSI  *  PSI ));
}

vec4 softSkin(vec4 originalColor, float factor) {
    vec4 screenColor = originalColor;
    float intensity = getLuminance(screenColor);
    float summ = 1.0;

    mat4 nextColor;
    nextColor[0] = BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp0.xy);
    nextColor[1] = BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp1.xy);
    nextColor[2] = BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp2.xy);
    nextColor[3] = BNB_TEXTURE_2D(BNB_SAMPLER_2D(bnb_BACKGROUND), sp3.xy);
    vec4 nextIntensity = getLuminance4(nextColor);
    vec4 curr = 0.367 * getWeight(intensity, nextIntensity);
    summ += dot(curr, vec4(1.0));
    screenColor += nextColor * curr;
    screenColor = screenColor / summ;

    screenColor = mix(originalColor, screenColor, factor);
    return screenColor;
}

float blendSoftLight(float a, float b) {
    return (a+2.*b*(1.-a))*a;
}

vec3 blendSoftLight(vec3 base, vec3 blend) {
    return vec3(blendSoftLight(base.r,blend.r),blendSoftLight(base.g,blend.g),blendSoftLight(base.b,blend.b));
}

vec3 blendSoftLight(vec3 base, vec3 blend, float opacity) {
    return (blendSoftLight(base, blend) * opacity + base * (1.0 - opacity));
}

void main()
{
    vec4 maskColor = BNB_TEXTURE_2D(BNB_SAMPLER_2D(selection_tex), var_uv);
    vec4 res = BNB_TEXTURE_2D( BNB_SAMPLER_2D(bnb_BACKGROUND), var_bg_uv );
    vec4 bg = BNB_TEXTURE_2D( BNB_SAMPLER_2D(bnb_BACKGROUND), var_uv );
#ifdef SOFT_SKIN
    res = softSkin(res, maskColor.r * skinSoftIntensity);
#endif

#ifdef SKIN_TEXTURING
    vec4 skinTexture = BNB_TEXTURE_2D(BNB_SAMPLER_2D(skin_tex), var_uv);
    vec4 diff = abs(skinTexture - res);
    res = mix(res, diff, skinTexturingIntensity);
#endif

#ifdef SHARPEN_TEETH
    res = sharpen(res, maskColor.g * teethSharpenIntensity);
#endif

#if defined(TEETH_WHITENING)
    res = teeth_whitening(res, maskColor.g * teethWhiteningCoeff);
#endif


#ifdef SHARPEN_EYES
    res = sharpen(res, maskColor.b * eyesSharpenIntensity);
#endif

#if defined(EYES_WHITENING)
    res = eyes_whitening(res, maskColor.b * eyesWhiteningCoeff);
#endif

    bnb_FragColor = res;
}