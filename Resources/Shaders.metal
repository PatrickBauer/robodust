#include <metal_stdlib>
using namespace metal;

// ---------- shared ----------
struct Globals { float2 viewport; float time; float pad; };

static inline float4 toClip(float2 p, float2 vp) {
    return float4(p.x / vp.x * 2 - 1, 1 - p.y / vp.y * 2, 0, 1);
}
constant float2 kQuad[6] = { {-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1} };

// ---------- wallpaper + freshly vacuumed lanes ----------
struct BgOut { float4 pos [[position]]; float2 uv; };
vertex BgOut bgVS(uint vid [[vertex_id]]) {
    float2 q = kQuad[vid]; BgOut o;
    o.pos = float4(q, 0, 1); o.uv = float2(q.x * .5 + .5, .5 - q.y * .5);
    return o;
}
fragment float4 bgFS(BgOut in [[stage_in]], texture2d<float> wall [[texture(0)]], texture2d<float> track [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = wall.sample(s, in.uv);
    // Wide blur: the nap should read as a soft sheen with no visible edge.
    float2 texel = 1.0 / float2(track.get_width(), track.get_height());
    float4 t = 0; float wsum = 0;
    for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
        float w = exp(-float(x*x + y*y) * 0.32);
        t += track.sample(s, in.uv + float2(x, y) * texel * 9.0) * w; wsum += w;
    }
    t /= wsum;
    float presence = t.r;
    if (presence > 0.004) {
        // Carpet-style nap: lanes driven in opposite directions catch the light differently.
        float nap = (t.g - .5) * 2;
        c.rgb += presence * nap * 0.017 * (0.5 + c.rgb);
    }
    return float4(c.rgb, 1);
}

// Track buffer stamps: r presence, g direction, b wheels.
struct StampU { float2 center; float2 half_; float angle; float dir; float pad0; float pad1; };
struct StampOut { float4 pos [[position]]; float2 q; float dir; };
vertex StampOut stampVS(uint vid [[vertex_id]], constant StampU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid]; float c = cos(u.angle), s = sin(u.angle);
    float2 l = q * u.half_; float2 w = u.center + float2(c*l.x - s*l.y, s*l.x + c*l.y);
    StampOut o; o.pos = toClip(w, g.viewport); o.q = q; o.dir = u.dir; return o;
}
fragment float4 stampFS(StampOut in [[stage_in]]) {
    float side = abs(in.q.y);
    if (side > .98 || abs(in.q.x) > .98) discard_fragment();
    float wheels = smoothstep(.09, .03, abs(side - .62));
    return float4(1, in.dir, wheels, 1);
}
vertex float4 fadeVS(uint vid [[vertex_id]]) { return float4(kQuad[vid], 0, 1); }
fragment float4 fadeFS(float4 p [[position]], constant float& amount [[buffer(0)]]) { return float4(amount, 0, 0, 0); }

// ---------- icons and labels ----------
struct Sprite {
    float2 center; float2 half_;
    float2 intake; float angle; float scale;
    float alpha; uint slice; float pull; float agit;
    float4 tint;
    float2 shadowOffset; float shadowAlpha; float pad;
};
struct Grid { float2 q; };
struct SpriteOut { float4 pos [[position]]; float2 uv; float alpha; uint slice [[flat]]; float4 tint; float shadowAlpha; };

static float2 warp(constant Sprite& I, float2 q) {
    float c = cos(I.angle), s = sin(I.angle);
    float2 l = q * I.half_ * 2.0 * I.scale;
    float2 w = I.center + float2(c*l.x - s*l.y, s*l.x + c*l.y);

    // Before it goes: the corners nearest the robot are already reaching for it.
    float2 toI = I.intake - w; float dist = length(toI);
    float reach = saturate(1.0 - dist / 300.0);
    if (dist > 1.0) w += toI / dist * I.agit * reach * reach * 34.0;

    if (I.pull > 0.0) {
        float2 axisV = I.intake - I.center; float axisL = max(length(axisV), 1.0);
        float2 A = axisV / axisL;
        float extent = max(length(I.half_) * I.scale, 1.0);
        float rel = dot(w - I.center, A) / extent;                  // +1 near edge, -1 far edge
        float tv = saturate(I.pull * 1.75 - 0.75 * (0.5 - 0.5 * rel));
        float e = tv * tv * (3.0 - 2.0 * tv);
        float2 d = w - I.intake;
        float along = dot(d, A);
        float2 perp = d - A * along;
        w = I.intake + A * along * (1.0 - e) + perp * pow(1.0 - e, 2.2);
    }
    return w;
}

vertex SpriteOut spriteVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Grid* grid [[buffer(0)]], constant Sprite* inst [[buffer(1)]],
                          constant Globals& g [[buffer(2)]]) {
    constant Sprite& I = inst[iid];
    float2 q = grid[vid].q;
    SpriteOut o;
    o.pos = toClip(warp(I, q), g.viewport);
    o.uv = q + .5; o.alpha = I.alpha; o.slice = I.slice; o.tint = I.tint; o.shadowAlpha = 0;
    return o;
}
vertex SpriteOut spriteShadowVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Grid* grid [[buffer(0)]], constant Sprite* inst [[buffer(1)]],
                                constant Globals& g [[buffer(2)]]) {
    constant Sprite& I = inst[iid];
    float2 q = grid[vid].q;
    SpriteOut o;
    o.pos = toClip(warp(I, q) + I.shadowOffset, g.viewport);
    o.uv = q + .5; o.alpha = I.alpha; o.slice = I.slice; o.tint = float4(0); o.shadowAlpha = I.shadowAlpha;
    return o;
}
fragment float4 spriteFS(SpriteOut in [[stage_in]], texture2d_array<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    float4 c = tex.sample(s, in.uv, in.slice);
    c.rgb = mix(c.rgb, in.tint.rgb * c.a, in.tint.a);
    return c * in.alpha;
}
fragment float4 spriteShadowFS(SpriteOut in [[stage_in]], texture2d_array<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float a = tex.sample(s, in.uv, in.slice, bias(2.2)).a;
    return float4(0, 0, 0, a * in.shadowAlpha * in.alpha);
}

// ---------- particles ----------
struct Part { float2 pos; float size; float ang; float4 color; float chip; float pad0; float pad1; float pad2; };
struct PartOut { float4 pos [[position]]; float2 q; float4 color; float chip; };
vertex PartOut partVS(uint vid [[vertex_id]], uint iid [[instance_id]], constant Part* p [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    constant Part& I = p[iid];
    float2 q = kQuad[vid]; float c = cos(I.ang), s = sin(I.ang);
    float2 l = q * I.size; if (I.chip > .5) l.y *= .55;
    PartOut o; o.pos = toClip(I.pos + float2(c*l.x - s*l.y, s*l.x + c*l.y), g.viewport);
    o.q = q; o.color = I.color; o.chip = I.chip; return o;
}
fragment float4 partFS(PartOut in [[stage_in]]) {
    float a = in.chip > .5 ? 1.0 : smoothstep(1.0, .35, length(in.q));
    return float4(in.color.rgb * in.color.a * a, in.color.a * a);
}

// ---------- generic quad for the procedural objects ----------
struct QuadU { float2 center; float2 half_; float angle; float pad0; float pad1; float pad2; };
struct QuadOut { float4 pos [[position]]; float2 p; };  // p in world points, relative to centre
vertex QuadOut quadVS(uint vid [[vertex_id]], constant QuadU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid]; float c = cos(u.angle), s = sin(u.angle);
    float2 l = q * u.half_; float2 r = float2(c*l.x - s*l.y, s*l.x + c*l.y);
    QuadOut o; o.pos = toClip(u.center + r, g.viewport); o.p = r; return o;
}

// Lighting shared by robot and dock. Light comes from upper-left of the screen, always.
static float3 studio(float3 r) {
    // A large softbox up and to the left, a dim strip opposite, dark room otherwise.
    float box = smoothstep(.06, .34, -r.x * .55 - r.y * .78) * smoothstep(1.0, .55, abs(r.x * .78 - r.y * .55));
    float strip = smoothstep(.72, .92, r.x * .5 + r.y * .85) * .22;
    return float3(.16, .17, .19) + float3(1.0, .98, .95) * box * .95 + float3(.75, .85, 1) * strip;
}
struct Mat { float3 albedo; float gloss; float metal; float emis; float3 emisColor; };
static float3 shade(float3 N, Mat m, float ao) {
    float3 L = normalize(float3(-.46, -.62, .64));
    float diff = saturate(dot(N, L) * .78 + .22);
    float sky = .52 + .48 * N.z;
    float3 col = m.albedo * (diff * float3(1.02, 1, .97) * .84 + sky * float3(.40, .42, .46));
    float3 V = float3(0, 0, 1);
    float3 R = reflect(-V, N);
    float fres = pow(1 - saturate(N.z), 3.0);
    float3 H = normalize(L + V);
    float sp = pow(saturate(dot(N, H)), mix(14.0, 180.0, m.gloss)) * mix(.12, 1.5, m.gloss);
    col += sp;
    float refl = mix(.03, .42, m.gloss) + fres * .5;
    col = mix(col, studio(R) * mix(float3(1), m.albedo * 1.3, m.metal), refl * mix(.5, 1.0, m.gloss));
    col *= ao;
    col += m.emisColor * m.emis;
    return col;
}
static inline float sdBox(float2 p, float2 b, float r) { float2 d = abs(p) - b + r; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r; }
static inline float groove(float d, float w) { return smoothstep(w, 0.0, abs(d)); }

// ---------- robot ----------
struct RobotU {
    float2 center; float radius; float heading;
    float lidar; float bumper; float binFill; float ledPulse;
    float4 led;
    float alpha; float shakeX; float shakeY; float lift;
};

struct RobotSurf { float h; int mat; float ao; };

static float robotHeight(float2 l, constant RobotU& u, thread int& mat, thread float& ao) {
    float r = length(l);
    float ang = atan2(l.y, l.x);
    // Body: a fat rounded shell with a very slight crown.
    float e = saturate((1.0 - r) / .14);
    float h = .30 * sqrt(1.0 - (1.0 - e) * (1.0 - e)) + .035 * (1.0 - r * r);
    mat = 0; ao = 1;

    // Bumper arc wraps the front; it physically moves in when struck.
    float inner = .845 - u.bumper * .018;
    bool front = abs(ang) < 1.85;
    float seam = groove(r - inner, .012) * (front ? 1.0 : 0.0);
    float endA = abs(abs(ang) - 1.85) * r;
    float seamEnd = groove(endA, .012) * step(inner, r) * step(r, .99);
    h -= .05 * max(seam, seamEnd);
    ao *= 1 - .72 * max(seam, seamEnd);
    if (front && r > inner) {
        mat = 1;
        // Dark sensor window along the leading edge.
        if (abs(ang) < .72 && r > .905 && r < .977) mat = 2;
    }

    // Graphite top plate, glossy, inset slightly.
    float plate = r - .70;
    float plateRim = groove(plate, .010);
    if (plate < 0) { h -= .010; h += .085 * (1.0 - (r*r)/(.70*.70)); mat = 3; }
    ao *= 1 - .45 * plateRim;

    // Hairline cut for the bin lid at the rear.
    float2 lidP = l - float2(-.46, 0);
    float lid = sdBox(lidP, float2(.135, .38), .07);
    if (plate < 0) { h -= .010 * groove(lid, .007); ao *= 1 - .4 * groove(lid, .006); }

    // Button pill.
    float2 pp = l - float2(-.17, 0);
    float pill = sdBox(pp, float2(.04, .17), .04);
    if (pill < 0) { mat = 4; h += .005; }
    ao *= 1 - .4 * groove(pill, .008);
    float b1 = length(l - float2(-.17, .085)) - .03, b2 = length(l - float2(-.17, -.085)) - .03;
    if (b1 < 0 || b2 < 0) { mat = 5; h -= .004; }

    // Lidar turret: the one thing that stands proud of the body.
    float2 tp = l - float2(.27, 0);
    float td = length(tp);
    float tR = .265;
    float te = saturate((tR - td) / .05);
    h += .11 * sqrt(1.0 - (1.0 - te) * (1.0 - te));
    if (td < tR) {
        mat = 6;
        if (td < .185) { mat = 7; h += .045 * (1.0 - td*td/(.185*.185)); }
    }
    ao *= 1 - .55 * smoothstep(tR + .05, tR, td) * step(tR, td);
    return h;
}

vertex QuadOut robotVS(uint vid [[vertex_id]], constant RobotU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid] * u.radius * 1.03;
    QuadOut o; o.pos = toClip(u.center + q + float2(u.shakeX, u.shakeY), g.viewport); o.p = q; return o;
}

fragment float4 robotFS(QuadOut in [[stage_in]], constant RobotU& u [[buffer(0)]], texture2d<float> logo [[texture(0)]]) {
    float2 wp = in.p / u.radius;
    float rr = length(wp);
    float px = fwidth(in.p.x) / u.radius;
    float edge = smoothstep(1.0, 1.0 - px * 1.5, rr);
    if (edge <= 0) discard_fragment();
    float c = cos(-u.heading), s = sin(-u.heading);
    float2 l = float2(c*wp.x - s*wp.y, s*wp.x + c*wp.y);

    int mat; float ao; int mm; float aa;
    const float E = .0035;
    float h0 = robotHeight(l, u, mat, ao);
    float hx = robotHeight(l + float2(E, 0), u, mm, aa) - robotHeight(l - float2(E, 0), u, mm, aa);
    float hy = robotHeight(l + float2(0, E), u, mm, aa) - robotHeight(l - float2(0, E), u, mm, aa);
    (void)h0;
    float2 g = float2(hx, hy) / (2 * E);
    // Back to world space so the light never rotates with the robot.
    float cw = cos(u.heading), sw = sin(u.heading);
    float2 gw = float2(cw*g.x - sw*g.y, sw*g.x + cw*g.y);
    float3 N = normalize(float3(-gw * 1.05, 1));

    Mat m; m.albedo = float3(.90, .90, .88); m.gloss = .28; m.metal = 0; m.emis = 0; m.emisColor = float3(0);
    switch (mat) {
        case 1: m.albedo = float3(.84, .84, .83); m.gloss = .20; break;       // bumper
        case 2: m.albedo = float3(.018, .019, .022); m.gloss = 1; break;      // sensor window
        case 3: m.albedo = float3(.055, .058, .065); m.gloss = .72; break;    // top plate
        case 4: m.albedo = float3(.035, .035, .04); m.gloss = .4; break;      // pill
        case 5: m.albedo = float3(.72, .73, .75); m.gloss = .5; m.metal = .6; break; // buttons
        case 6: m.albedo = float3(.62, .62, .62); m.gloss = .16; break;       // turret skirt
        case 7: m.albedo = float3(.015, .016, .02); m.gloss = 1; break;       // turret dome
    }

    // Spinning laser head, seen through the smoked dome.
    float2 tp = l - float2(.27, 0);
    float td = length(tp);
    float3 extra = float3(0);
    if (mat == 7) {
        float2 gl = float2(cos(u.lidar), sin(u.lidar)) * .105;
        extra += float3(.45, .85, 1.0) * exp(-dot(tp - gl, tp - gl) * 1500.0) * .9;
        extra += float3(.45, .85, 1.0) * exp(-dot(tp + gl * .9, tp + gl * .9) * 2600.0) * .25;
    }
    // Status ring around the turret.
    float ring = groove(td - .225, .009);
    float pulse = .62 + .38 * sin(u.ledPulse * 3.0);
    m.emis = ring * pulse * 1.15;
    m.emisColor = u.led.rgb;
    // Button glyph glow.
    float glow1 = exp(-pow(length(l - float2(-.17, .085)) / .022, 2));
    extra += u.led.rgb * glow1 * .5;

    // Logotype on the graphite plate.
    float2 luv = float2((l.y + .31) / .62, (-l.x - .42) / .218);
    if (all(luv > 0.0) && all(luv < 1.0) && length(l) < .70) {
        constexpr sampler ss(filter::linear, address::clamp_to_edge);
        float la = logo.sample(ss, luv).a;
        m.albedo = mix(m.albedo, float3(.62, .64, .68), la * .85);
    }

    float3 col = shade(N, m, ao) + extra;
    // Grounding: the rim rolls off a touch into its own shadow.
    col *= mix(.7, 1.0, smoothstep(1.0, .90, rr));
    return float4(col * edge * u.alpha, edge * u.alpha);
}

// Rotating side brush; blurs into a disc as it speeds up.
struct BrushU { float2 center; float radius; float angle; float speed; float alpha; float sign_; float pad; };
vertex QuadOut brushVS(uint vid [[vertex_id]], constant BrushU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid] * u.radius;
    QuadOut o; o.pos = toClip(u.center + q, g.viewport); o.p = q; return o;
}
fragment float4 brushFS(QuadOut in [[stage_in]], constant BrushU& u [[buffer(0)]]) {
    float2 p = in.p / u.radius;
    float r = length(p);
    if (r > 1) discard_fragment();
    float a = atan2(p.y, p.x) * u.sign_ - u.angle;
    float blur = saturate(u.speed / 26.0);
    float total = 0;
    for (int i = 0; i < 3; i++) {
        // Bristle arms curve backwards against the spin.
        float armA = a + i * 2.0944 - r * .55;
        armA = atan2(sin(armA), cos(armA));
        float w = mix(.035, .46, blur) + .07 * (1 - r);
        float m = exp(-armA * armA / (w * w));
        float fray = .72 + .28 * sin(armA * 60.0 + r * 3.0);
        total += m * fray;
    }
    float fade = smoothstep(1.0, .78, r);
    float alpha = saturate(total) * fade * mix(.96, .52, blur);
    float hub = smoothstep(.17, .13, r);
    float3 bristle = mix(float3(.10, .10, .11), float3(.62, .62, .66), r * r);
    float3 col = mix(bristle, float3(.04), hub);
    float aOut = max(alpha, hub) * u.alpha;
    return float4(col * aOut, aOut);
}

// Soft drop shadows.
struct ShadowU { float2 center; float radius; float strength; float2 offset; float blur; float kind; float2 halfBox; float angle; float pad; };
vertex QuadOut shadowVS(uint vid [[vertex_id]], constant ShadowU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 ext = u.kind > .5 ? (u.halfBox + u.blur * 2 + 6) : float2(u.radius + u.blur * 2 + 6);
    float c = cos(u.angle), s = sin(u.angle);
    float2 l = kQuad[vid] * ext; float2 q = float2(c*l.x - s*l.y, s*l.x + c*l.y);
    QuadOut o; o.pos = toClip(u.center + u.offset + q, g.viewport); o.p = q; return o;
}
fragment float4 shadowFS(QuadOut in [[stage_in]], constant ShadowU& u [[buffer(0)]]) {
    float d;
    if (u.kind > .5) {
        float c = cos(-u.angle), s = sin(-u.angle);
        float2 l = float2(c*in.p.x - s*in.p.y, s*in.p.x + c*in.p.y);
        d = sdBox(l, u.halfBox, u.radius);
    } else { d = length(in.p) - u.radius; }
    float a = 1 - smoothstep(-u.blur, u.blur, d);
    a = a * a * (3 - 2 * a);
    return float4(0, 0, 0, a * u.strength);
}

// ---------- dock ----------
struct DockU { float2 center; float radius; float alpha; float bag; float glow; float ledPulse; float pad0; float4 led; };
vertex QuadOut dockVS(uint vid [[vertex_id]], constant QuadU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid] * u.half_;
    QuadOut o; o.pos = toClip(u.center + q, g.viewport); o.p = q; return o;
}
static float dockHeight(float2 d, thread int& mat, thread float& ao) {
    // d: x sideways, y outward from the back wall, in robot radii, origin at docked robot centre.
    ao = 1; mat = 0;
    float rampD = sdBox(d - float2(0, -.20), float2(1.14, .98), .24);
    float h = 0;
    if (rampD < 0) {
        float e = saturate(-rampD / .05);
        h = .05 * sqrt(1 - (1-e)*(1-e));
        mat = 1;
        // Non-slip ribs fade towards the lip.
        float rib = sin(d.y * 90.0) * smoothstep(.72, .1, d.y) * .0022 * smoothstep(-.06, -.2, rampD);
        h += rib;
    }
    // Charge contacts.
    float2 cp = float2(abs(d.x) - .42, d.y + .78);
    float contact = sdBox(cp, float2(.13, .04), .03);
    if (contact < 0 && rampD < 0) { mat = 2; h += .012; }

    // Tower behind the robot.
    float2 tc = d - float2(0, -1.50);
    float tower = sdBox(tc, float2(1.26, .58), .30);
    if (tower < 0) {
        float e = saturate(-tower / .13);
        h = .40 * sqrt(1 - (1-e)*(1-e));
        mat = 3;
        // Bag window.
        float win = sdBox(d - float2(0, -1.50), float2(.76, .29), .11);
        if (win < 0) { mat = 4; h = .34 + .0 * win; }
        ao *= 1 - .6 * groove(win, .014);
        // Vents at each end.
        float2 vp = float2(abs(d.x) - 1.05, d.y + 1.50);
        if (abs(vp.x) < .09 && abs(vp.y) < .26) {
            float slit = smoothstep(.2, .7, sin(vp.y * 62.0));
            h -= .014 * slit; ao *= 1 - .55 * slit;
        }
    }
    ao *= 1 - .5 * groove(tower, .02);
    return h;
}
fragment float4 dockFS(QuadOut in [[stage_in]], constant DockU& u [[buffer(0)]], texture2d<float> logo [[texture(0)]]) {
    // Dock faces up the screen: outward = -y.
    float2 d = float2(in.p.x, -in.p.y) / u.radius;
    int mat, mm; float ao, aa;
    const float E = .004;
    float h0 = dockHeight(d, mat, ao);
    float hx = dockHeight(d + float2(E,0), mm, aa) - dockHeight(d - float2(E,0), mm, aa);
    float hy = dockHeight(d + float2(0,E), mm, aa) - dockHeight(d - float2(0,E), mm, aa);
    if (h0 <= 0.0001) discard_fragment();
    float2 g = float2(hx, -hy) / (2 * E);
    float3 N = normalize(float3(-g, 1));
    Mat m; m.albedo = float3(.9, .9, .88); m.gloss = .3; m.metal = 0; m.emis = 0; m.emisColor = float3(0);
    float3 extra = float3(0);
    if (mat == 1) { m.albedo = float3(.10, .105, .115); m.gloss = .18; }
    if (mat == 2) { m.albedo = float3(.95, .78, .42); m.gloss = .85; m.metal = 1; }
    if (mat == 4) {
        // Dust bag behind smoked glass: a pillow that grows and glows as it fills.
        float2 w = d - float2(0, -1.50);
        float fill = u.bag;
        float bx = .72 * (.3 + .7 * sqrt(fill));
        float bag = sdBox(w, float2(bx, .25), .10);
        float inside = smoothstep(.01, -.01, bag);
        float puff = sqrt(saturate(-bag / .13));
        float3 base = float3(.04, .045, .05);
        float wr = sin(w.x * 21.0 + w.y * 11.0) * sin(w.y * 37.0 - w.x * 9.0);
        float3 bagc = mix(float3(.34, .36, .39), float3(.72, .73, .74), puff) * (1 + .04 * wr);
        m.albedo = mix(base, bagc, inside * .85);
        m.gloss = .9;
        extra += float3(.25, .6, .9) * u.glow * .24 * (.3 + inside);
    }
    // LED strip along the tower's front edge.
    float2 lp = d - float2(0, -.98);
    if (abs(lp.x) < .34 && abs(lp.y) < .012 + .004) {
        m.emis = (.65 + .35 * sin(u.ledPulse * 2.4)) * 1.1;
        m.emisColor = u.led.rgb;
    }
    float3 col = shade(N, m, ao) + extra;
    float2 luv = float2((d.x + .34) / .68, (d.y + 2.03 - .04) / .19);
    if (all(luv > 0.0) && all(luv < 1.0)) {
        constexpr sampler ss(filter::linear, address::clamp_to_edge);
        float la = logo.sample(ss, float2(luv.x, 1 - luv.y)).a;
        col = mix(col, float3(.32, .33, .35), la * .85);
    }
    float a = u.alpha * smoothstep(0.0, .012, h0);
    return float4(col * a, a);
}

// ---------- lidar sweep ----------
struct LidarU { float2 center; float radius; float angle; float alpha; float pad0; float pad1; float pad2; };
vertex QuadOut lidarVS(uint vid [[vertex_id]], constant LidarU& u [[buffer(0)]], constant Globals& g [[buffer(1)]]) {
    float2 q = kQuad[vid] * u.radius;
    QuadOut o; o.pos = toClip(u.center + q, g.viewport); o.p = q; return o;
}
fragment float4 lidarFS(QuadOut in [[stage_in]], constant LidarU& u [[buffer(0)]]) {
    float r = length(in.p) / u.radius;
    if (r > 1) discard_fragment();
    float a = atan2(in.p.y, in.p.x) - u.angle;
    a = fmod(-a + 62.83185 * 4, 6.283185);           // radians behind the beam
    float tail = exp(-a * 2.4) * .26;
    float line = exp(-a * a * 1800.0) * .55;
    float rings = (smoothstep(.012, 0.0, abs(fract(r * 9.0) - .5) / 9.0)) * .05 * exp(-a * 1.2);
    float fall = pow(1 - r, .35);
    float i = (tail + line + rings) * fall * u.alpha;
    float3 c = float3(.32, .86, 1.0);
    return float4(c * i, i * .55);
}
