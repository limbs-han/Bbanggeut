// =============================================================================
//  BRIO 100  Pan / Tilt  Camera Mount  for  Jetson Orin Nano
//  Parametric CAD (OpenSCAD)  ->  export STL per part
// -----------------------------------------------------------------------------
//  Form reference : Thingiverse thing:1062468 "Pi-Cam" (2x micro-servo pan/tilt)
//  Camera         : Logitech BRIO 100  (72.9 x 31.9 x ~26 mm body, 75 g)
//  Servos         : 2x SG90 / MG90S micro servo (metal-gear MG90S recommended)
//  Controller     : NVIDIA Jetson Orin Nano Dev Kit  (drives servos via PCA9685)
//
//  HOW TO USE
//    1. Open in OpenSCAD (free).  Edit the parameters below with YOUR measured
//       numbers (anything marked  *** VERIFY ***  MUST be re-measured).
//    2. Set  part = "base" | "pan_platform" | "cradle"  and  F6 (render),
//       then  File > Export > STL.  Print the 3 parts.
//    3. "all" lays out every part for a quick visual check (do NOT export "all").
//
//  UNITS: millimetres.  Coordinate: Z = up, tilt axis is along X, pan axis = Z.
// =============================================================================

part = "all";          // [base, pan_platform, cradle, all]

/* [Print quality / fit] */
$fn        = 72;
wall       = 3.0;      // general wall thickness (>=3 perimeters for strength)
clr        = 0.4;      // clearance/fit gap for mating printed parts (FDM ~0.3-0.5)
screw_clr  = 0.2;      // extra on through-holes

/* [Micro servo  SG90 / MG90S]  (identical footprint) */
sv_l       = 23.0;     // body length  (+clr added in code)
sv_w       = 12.6;     // body width
sv_h       = 22.7;     // body height (bottom -> top of body, excl. shaft)
sv_tab_w   = 32.5;     // tip-to-tip across the two mounting ears
sv_tab_t   = 2.6;      // ear thickness
sv_tab_z   = 15.8;     // ear underside height, from body bottom
sv_hole_d  = 2.4;      // ear screw hole (M2 self-tap)
sv_hole_span = 28.0;   // center-to-center of the two ear holes
sv_shaft_off = 6.0;    // output-shaft center, offset from body center (along L)
sv_shaft_d = 4.8;      // spline/shaft boss clearance
horn_screw_d = 2.2;    // M2 screw into the servo horn (self-tap)
horn_r     = 7.0;      // radius out to the horn screw holes (round horn ~ dia14-20)

/* [Camera  Logitech BRIO 100]
   IMPORTANT: the fold-out clip is NON-removable and there is NO 1/4" tripod
   thread. So we DO NOT enclose the camera in a box. Instead we print a thin
   "monitor-edge" BLADE and let the camera's own clip clamp onto it (exactly as
   it clamps a monitor top edge). Removable, no glue, uses the intended grip. */
cam_w      = 73.0;     // camera width (used to size platform span)   *** VERIFY ***

/* [Clip-grip blade] tune panel_t / panel_h by test-fitting YOUR clip */
panel_w    = 78.0;     // blade width  (>= cam_w so the full clip contacts)
panel_t    = 9.0;      // blade thickness the clip grips (monitor-edge sim, try 6-14)
panel_h    = 46.0;     // blade height below the top edge (room for clip's rear leg)
ledge_d    = 10.0;     // front shelf under top edge -> seats clip lip, sets cam angle
grip_clr   = 0.3;      // small print gap

/* [Cable exit]  the BRIO cable is captive USB-A; route it out the back-bottom */
cable_w    = 9.0;      // cable channel width  (round-cable friendly)
cable_h    = 6.5;      // cable channel height
strain_d   = 3.4;      // zip-tie / strain-relief hole (M3)

/* [Base -> Jetson / tripod mount]  *** VERIFY Jetson hole pitch on YOUR unit *** */
mount_pattern = "grid";   // [grid, jetson]
grid_dx    = 30.0;     // generic bolt pattern X (fits most brackets / GoPro plates)
grid_dy    = 30.0;     // generic bolt pattern Y
jetson_dx  = 86.0;     // *** VERIFY *** Jetson devkit mount-hole pitch X
jetson_dy  = 58.0;     // *** VERIFY *** Jetson devkit mount-hole pitch Y
base_hole_d = 3.4;     // M3 clearance (M2.5 for Jetson -> set 2.9)
base_ft    = 4.0;      // base floor thickness

// ---- derived ---------------------------------------------------------------
SV_L = sv_l + clr;
SV_W = sv_w + clr;
hub_ext = 6;           // how far the tilt hubs stick out to reach the walls
eps  = 0.01;

// =============================================================================
//  SHARED MODULES
// =============================================================================

// Servo body cavity (open pocket). Origin at body-bottom center.
// The output shaft points +Z. Ears sit at height sv_tab_z.
module servo_pocket(depth_extra=0){
    // body cavity
    translate([0,0,-eps]) cube([SV_L, SV_W, sv_h+depth_extra+eps], center=true);
    // ear screw holes (span along length)
    for(x=[-sv_hole_span/2, sv_hole_span/2])
        translate([x,0,sv_tab_z]) rotate([0,0,0])
            cylinder(h=sv_tab_t*4, d=sv_hole_d, center=true);
}

// Round horn interface: center bore + 2 opposed screw holes to grab a servo horn
module horn_interface(){
    cylinder(h=40, d=sv_shaft_d+screw_clr*2, center=true);           // shaft clear
    for(a=[0,180]) rotate([0,0,a]) translate([horn_r,0,0])
        cylinder(h=40, d=horn_screw_d, center=true);                 // horn screws
}

module bolt_pattern(dx,dy,d){
    for(x=[-dx/2,dx/2], y=[-dy/2,dy/2])
        translate([x,y,0]) cylinder(h=100, d=d, center=true);
}

// =============================================================================
//  PART 1 — BASE  (houses the PAN servo, shaft up; bolts to Jetson/tripod)
// =============================================================================
base_x = 46;
base_y = 40;
top_t  = 3.0;                          // top plate thickness (pan servo mounts here)
base_h = sv_tab_z + top_t + 4;         // body hangs below the top plate + clearance

module base(){
    hh = base_h - base_ft - top_t;     // interior cavity height (for servo body + wiring)
    difference(){
        union(){
            // hollow tower
            translate([0,0,base_h/2])
                cube([base_x, base_y, base_h], center=true);
            // wide foot flange
            translate([0,0,base_ft/2])
                cube([base_x+16, base_y+16, base_ft], center=true);
        }
        // interior cavity — leave a floor (base_ft) AND a top plate (top_t)
        translate([0,0, base_ft + hh/2])
            cube([base_x-2*wall, base_y-2*wall, hh+eps], center=true);

        // PAN servo: body passes through the top plate, ears rest ON TOP, shaft up.
        // shaft is centred on Z (body offset by -sv_shaft_off).
        translate([-sv_shaft_off, 0, base_h-top_t/2])
            cube([SV_L, SV_W, top_t+2+2*eps], center=true);
        // ear screw holes into the top plate
        for(x=[-sv_hole_span/2, sv_hole_span/2])
            translate([-sv_shaft_off + x, 0, base_h-top_t/2])
                cylinder(h=top_t+6, d=sv_hole_d, center=true);

        // mounting bolt pattern (bolt up from underneath into Jetson standoffs / plate)
        if(mount_pattern=="grid") bolt_pattern(grid_dx, grid_dy, base_hole_d);
        else                      bolt_pattern(jetson_dx, jetson_dy, base_hole_d);

        // cable exit slot in the back wall (servo wire + camera cable pass)
        translate([0, base_y/2, base_ft+cable_h/2+1])
            cube([cable_w, wall*4, cable_h], center=true);
    }
}

// =============================================================================
//  PART 2 — PAN PLATFORM  (rides on pan-servo horn; carries the TILT servo)
//  U-bracket: left wall = tilt-servo holder, right wall = idler pivot bearing.
// =============================================================================
gap        = panel_w + 2*hub_ext + 2*grip_clr + 4; // inner span between the two walls
plat_t     = 4.0;                                // platform floor thickness
wall_h     = 46;                                 // upright wall height (encloses servo cut)
wall_t     = 5.0;                                // wall thickness
wall_y     = 32;                                 // wall depth (Y)
tilt_axis_z = plat_t + 24;                        // height of the tilt axis

// Horizontal servo cut in a wall at X=wall_cx: body slot (outboard) + 2 ear holes + shaft.
// The servo BODY sits outboard in open air (no collision with cradle); the shaft pokes
// inward through the wall to the cradle's horn; ears screw to the wall's outer face.
module tilt_servo_cut(wall_cx){
    // body / shaft through-slot (width=SV_W in Y, length=sv_l in Z)
    translate([wall_cx, 0, tilt_axis_z]) cube([wall_t*4, SV_W, sv_l], center=true);
    // ear screw holes (ears sit along the length = Z, spaced sv_hole_span)
    for(z=[-sv_hole_span/2, sv_hole_span/2])
        translate([wall_cx, 0, tilt_axis_z+z]) rotate([0,90,0])
            cylinder(h=wall_t*4, d=sv_hole_d, center=true);
}

module pan_platform(){
    difference(){
        union(){
            // floor plate (round, clears the base footprint while panning)
            cylinder(h=plat_t, d=gap+2*wall_t+8);
            // two upright walls
            for(s=[-1,1])
                translate([s*(gap/2+wall_t/2), 0, 0])
                    translate([-wall_t/2,-wall_y/2,0]) cube([wall_t, wall_y, wall_h]);
        }
        // interface to the PAN-servo horn (bottom center)
        horn_interface();
        // LEFT wall: tilt servo (body outboard, shaft inward)
        tilt_servo_cut(-(gap/2+wall_t/2));
        // RIGHT wall: idler bearing bore (coaxial with tilt axis) for the 6 mm axle
        translate([(gap/2+wall_t/2),0,tilt_axis_z])
            rotate([0,90,0]) cylinder(h=wall_t*4, d=6.2, center=true);
    }
}

// =============================================================================
//  PART 3 — CRADLE  =  a "monitor-edge" BLADE that the BRIO 100 clip grips.
//  The camera's own (non-removable) clip hooks over the blade's TOP edge with
//  the lens facing forward (-Y); the clip's rear leg braces the back (+Y).
//  The blade pivots on the tilt axis (X). Hubs sit near the top = near the
//  camera CoG, minimising tilt-servo torque.
//    Blade: X centered, front face at Y=0, back at Y=panel_t, base Z=0..panel_h.
// =============================================================================
hub_z = panel_h - 14;                 // tilt axis, just below the top edge (near CoG)

module cradle(){
    w = panel_w; t = panel_t; h = panel_h;
    difference(){
        union(){
            // the blade the clip clamps onto
            translate([-w/2, 0, 0]) cube([w, t, h]);
            // front shelf under the top edge -> seats the clip's inner lip
            translate([-w/2, -ledge_d, h-3]) cube([w, ledge_d+t, 3]);
            // reinforcing fillets at the shelf root
            translate([-w/2, 0, h-8]) cube([w, 3, 5]);
            // tilt hubs, extending outward to meet the platform walls
            for(s=[-1,1])
                translate([s*(w/2+hub_ext/2), t/2, hub_z])
                    rotate([0,90,0]) cylinder(h=hub_ext, d=18, center=true);
        }
        // cable channel: recessed groove down the BACK face to the bottom
        translate([-cable_w/2, t-2.5, -eps]) cube([cable_w, 3, h-10]);
        // strain-relief / retention zip-tie holes (through the blade, low down)
        for(x=[-cable_w, cable_w])
            translate([x, -eps, 12]) rotate([-90,0,0])
                cylinder(h=t+2, d=strain_d);
        // LEFT hub: servo-horn interface (2 screws grab the horn)
        translate([-(w/2+hub_ext), t/2, hub_z]) rotate([0,90,0]) horn_interface();
        // RIGHT hub: stub-axle bore (press-fit a 6mm bolt/pin as the idler axle)
        translate([ (w/2+hub_ext), t/2, hub_z]) rotate([0,90,0])
            cylinder(h=hub_ext*3, d=6.0-clr, center=true);
    }
}

// =============================================================================
//  LAYOUT
// =============================================================================
if(part=="base")          base();
else if(part=="pan_platform") pan_platform();
else if(part=="cradle")   cradle();
else {                     // "all" — visual sanity check only
    base();
    translate([0,0,base_h+3])        color("orange") pan_platform();
    translate([0,0,base_h+tilt_axis_z]) color("skyblue") cradle();
}
