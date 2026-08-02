#include <bnb/glsl.vert>

precision mediump float;
precision mediump int;

BNB_LAYOUT_LOCATION(0) BNB_IN vec3 attrib_pos;
BNB_LAYOUT_LOCATION(1) BNB_IN vec3 attrib_pos_static;
BNB_LAYOUT_LOCATION(2) BNB_IN vec2 attrib_uv;
BNB_LAYOUT_LOCATION(3) BNB_IN vec4 attrib_red_mask;

BNB_OUT(0) vec2 var_uv;
BNB_OUT(1) vec2 var_bg_uv;
BNB_OUT(2) vec3 maskColor;
BNB_OUT(3+0) vec4 sp0;
BNB_OUT(3+1) vec4 sp1;
BNB_OUT(3+2) vec4 sp2;
BNB_OUT(3+3) vec4 sp3;


invariant gl_Position;

const float dx = 1.0 / 720.0;
const float dy = 1.0 / 1280.0;

const float delta = 5.;

const float sOfssetXneg = -delta * dx;
const float sOffsetYneg = -delta * dy;
const float sOffsetXpos = delta * dx;
const float sOffsetYpos = delta * dy;

void main()
{
    gl_Position = bnb_MVP * vec4( attrib_pos, 1. );

    var_uv = attrib_uv;
    var_bg_uv  = (gl_Position.xy / gl_Position.w) * 0.5 + 0.5;
#ifdef BNB_VK_1
    var_bg_uv.y = 1. - var_bg_uv.y;
#endif
    
    sp0.xy = var_bg_uv + vec2(sOfssetXneg, sOffsetYneg);
    sp1.xy = var_bg_uv + vec2(sOfssetXneg, sOffsetYpos);
    sp2.xy = var_bg_uv + vec2(sOffsetXpos, sOffsetYneg);
    sp3.xy = var_bg_uv + vec2(sOffsetXpos, sOffsetYpos);
    
    vec2 delta = vec2(dx, dy);
    sp0.zw = var_bg_uv + vec2(-delta.x, -delta.y);
    sp1.zw = var_bg_uv + vec2(delta.x, -delta.y);
    sp2.zw = var_bg_uv + vec2(-delta.x, delta.y);
    sp3.zw = var_bg_uv + vec2(delta.x, delta.y);
}