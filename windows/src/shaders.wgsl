// WGSL port of Resources/Shaders.metal. Same maths, same look.

struct Globals { viewport: vec2f, time: f32, pad: f32 };

@group(0) @binding(0) var<uniform> g: Globals;
@group(0) @binding(2) var linearSampler: sampler;
@group(0) @binding(5) var spriteSampler: sampler;
@group(1) @binding(0) var tex0: texture_2d<f32>;
@group(1) @binding(1) var tex1: texture_2d<f32>;
@group(1) @binding(2) var texArr: texture_2d_array<f32>;

fn toClip(p: vec2f) -> vec4f {
    return vec4f(p.x / g.viewport.x * 2.0 - 1.0, 1.0 - p.y / g.viewport.y * 2.0, 0.0, 1.0);
}
fn quad(vid: u32) -> vec2f {
    var k = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0), vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
    return k[vid];
}
fn rot(l: vec2f, a: f32) -> vec2f {
    let c = cos(a);
    let s = sin(a);
    return vec2f(c * l.x - s * l.y, s * l.x + c * l.y);
}

// ---------- wallpaper + freshly vacuumed lanes ----------
struct BgOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
@vertex fn bgVS(@builtin(vertex_index) vid: u32) -> BgOut {
    let q = quad(vid);
    var o: BgOut;
    o.pos = vec4f(q, 0.0, 1.0);
    o.uv = vec2f(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    return o;
}
// Wide blur of the track buffer (tex1) into a quarter-size texture: the nap should read as a
// soft sheen with no visible edge. Done once per change instead of per screen pixel per frame.
@fragment fn trackBlurFS(i: BgOut) -> @location(0) vec4f {
    let texel = 1.0 / vec2f(textureDimensions(tex1));
    var t = vec4f(0.0);
    var wsum = 0.0;
    for (var y = -2; y <= 2; y++) {
        for (var x = -2; x <= 2; x++) {
            let w = exp(-f32(x * x + y * y) * 0.32);
            t += textureSampleLevel(tex1, linearSampler, i.uv + vec2f(f32(x), f32(y)) * texel * 9.0, 0.0) * w;
            wsum += w;
        }
    }
    return t / wsum;
}

// tex0 wallpaper, tex1 the blurred track.
@fragment fn bgFS(i: BgOut) -> @location(0) vec4f {
    var c = textureSampleLevel(tex0, linearSampler, i.uv, 0.0);
    let t = textureSampleLevel(tex1, linearSampler, i.uv, 0.0);
    let presence = t.r;
    if (presence > 0.004) {
        // Carpet-style nap: lanes driven in opposite directions catch the light differently.
        let nap = (t.g - 0.5) * 2.0;
        c = vec4f(c.rgb + presence * nap * 0.017 * (0.5 + c.rgb), c.a);
    }
    return vec4f(c.rgb, 1.0);
}

// Track buffer stamps: r presence, g direction, b wheels.
struct StampU { center: vec2f, half_: vec2f, angle: f32, dir: f32, pad0: f32, pad1: f32 };
@group(0) @binding(1) var<uniform> stampU: StampU;
struct StampOut { @builtin(position) pos: vec4f, @location(0) q: vec2f, @location(1) dir: f32 };
@vertex fn stampVS(@builtin(vertex_index) vid: u32) -> StampOut {
    let q = quad(vid);
    let w = stampU.center + rot(q * stampU.half_, stampU.angle);
    var o: StampOut;
    o.pos = toClip(w);
    o.q = q;
    o.dir = stampU.dir;
    return o;
}
@fragment fn stampFS(i: StampOut) -> @location(0) vec4f {
    let side = abs(i.q.y);
    if (side > 0.98 || abs(i.q.x) > 0.98) { discard; }
    let wheels = smoothstep(0.09, 0.03, abs(side - 0.62));
    return vec4f(1.0, i.dir, wheels, 1.0);
}
struct FadeU { amount: f32, p0: f32, p1: f32, p2: f32 };
@group(0) @binding(1) var<uniform> fadeU: FadeU;
@vertex fn fadeVS(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4f { return vec4f(quad(vid), 0.0, 1.0); }
@fragment fn fadeFS() -> @location(0) vec4f { return vec4f(fadeU.amount, 0.0, 0.0, 0.0); }

// ---------- icons and labels ----------
struct Sprite {
    center: vec2f, half_: vec2f,
    intake: vec2f, angle: f32, scale: f32,
    alpha: f32, slice: u32, pull: f32, agit: f32,
    tint: vec4f,
    shadowOffset: vec2f, shadowAlpha: f32, pad: f32,
};
@group(0) @binding(3) var<storage, read> sprites: array<Sprite>;
struct SpriteOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) alpha: f32,
    @location(2) @interpolate(flat) slice: u32,
    @location(3) tint: vec4f,
    @location(4) shadowAlpha: f32,
};

const GRID: u32 = 14u;
fn gridVertex(vid: u32) -> vec2f {
    let cell = vid / 6u;
    let corner = vid % 6u;
    var off = array<vec2f, 6>(vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0), vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0));
    let ij = vec2f(f32(cell % GRID), f32(cell / GRID));
    return (ij + off[corner]) / f32(GRID) - 0.5;
}

fn warp(I: Sprite, q: vec2f) -> vec2f {
    var w = I.center + rot(q * I.half_ * 2.0 * I.scale, I.angle);

    // Before it goes: the corners nearest the robot are already reaching for it.
    let toI = I.intake - w;
    let dist = length(toI);
    let reach = saturate(1.0 - dist / 300.0);
    if (dist > 1.0) { w += toI / dist * I.agit * reach * reach * 34.0; }

    if (I.pull > 0.0) {
        let axisV = I.intake - I.center;
        let axisL = max(length(axisV), 1.0);
        let A = axisV / axisL;
        let extent = max(length(I.half_) * I.scale, 1.0);
        let rel = dot(w - I.center, A) / extent;                  // +1 near edge, -1 far edge
        let tv = saturate(I.pull * 1.75 - 0.75 * (0.5 - 0.5 * rel));
        let e = tv * tv * (3.0 - 2.0 * tv);
        let d = w - I.intake;
        let along = dot(d, A);
        let perp = d - A * along;
        w = I.intake + A * along * (1.0 - e) + perp * pow(1.0 - e, 2.2);
    }
    return w;
}

@vertex fn spriteVS(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> SpriteOut {
    let I = sprites[iid];
    let q = gridVertex(vid);
    var o: SpriteOut;
    o.pos = toClip(warp(I, q));
    o.uv = q + 0.5;
    o.alpha = I.alpha;
    o.slice = I.slice;
    o.tint = I.tint;
    o.shadowAlpha = 0.0;
    return o;
}
@vertex fn spriteShadowVS(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> SpriteOut {
    let I = sprites[iid];
    let q = gridVertex(vid);
    var o: SpriteOut;
    o.pos = toClip(warp(I, q) + I.shadowOffset);
    o.uv = q + 0.5;
    o.alpha = I.alpha;
    o.slice = I.slice;
    o.tint = vec4f(0.0);
    o.shadowAlpha = I.shadowAlpha;
    return o;
}
@fragment fn spriteFS(i: SpriteOut) -> @location(0) vec4f {
    var c = textureSample(texArr, spriteSampler, i.uv, i.slice);
    c = vec4f(mix(c.rgb, i.tint.rgb * c.a, i.tint.a), c.a);
    return c * i.alpha;
}
@fragment fn spriteShadowFS(i: SpriteOut) -> @location(0) vec4f {
    let a = textureSampleBias(texArr, spriteSampler, i.uv, i.slice, 2.2).a;
    return vec4f(0.0, 0.0, 0.0, a * i.shadowAlpha * i.alpha);
}

// ---------- particles ----------
struct Part { pos: vec2f, size: f32, ang: f32, color: vec4f, chip: f32, pad0: f32, pad1: f32, pad2: f32 };
@group(0) @binding(4) var<storage, read> parts: array<Part>;
struct PartOut { @builtin(position) pos: vec4f, @location(0) q: vec2f, @location(1) color: vec4f, @location(2) chip: f32 };
@vertex fn partVS(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> PartOut {
    let I = parts[iid];
    let q = quad(vid);
    var l = q * I.size;
    if (I.chip > 0.5) { l.y *= 0.55; }
    var o: PartOut;
    o.pos = toClip(I.pos + rot(l, I.ang));
    o.q = q;
    o.color = I.color;
    o.chip = I.chip;
    return o;
}
@fragment fn partFS(i: PartOut) -> @location(0) vec4f {
    let a = select(smoothstep(1.0, 0.35, length(i.q)), 1.0, i.chip > 0.5);
    return vec4f(i.color.rgb * i.color.a * a, i.color.a * a);
}

// ---------- lighting shared by robot and dock ----------
struct QuadOut { @builtin(position) pos: vec4f, @location(0) p: vec2f };

// Light comes from upper-left of the screen, always.
fn studio(r: vec3f) -> vec3f {
    // A large softbox up and to the left, a dim strip opposite, dark room otherwise.
    let box = smoothstep(0.06, 0.34, -r.x * 0.55 - r.y * 0.78) * smoothstep(1.0, 0.55, abs(r.x * 0.78 - r.y * 0.55));
    let strip = smoothstep(0.72, 0.92, r.x * 0.5 + r.y * 0.85) * 0.22;
    return vec3f(0.16, 0.17, 0.19) + vec3f(1.0, 0.98, 0.95) * box * 0.95 + vec3f(0.75, 0.85, 1.0) * strip;
}
struct Mat { albedo: vec3f, gloss: f32, metal: f32, emis: f32, emisColor: vec3f };
fn shade(N: vec3f, m: Mat, ao: f32) -> vec3f {
    let L = normalize(vec3f(-0.46, -0.62, 0.64));
    let diff = saturate(dot(N, L) * 0.78 + 0.22);
    let sky = 0.52 + 0.48 * N.z;
    var col = m.albedo * (diff * vec3f(1.02, 1.0, 0.97) * 0.84 + sky * vec3f(0.40, 0.42, 0.46));
    let V = vec3f(0.0, 0.0, 1.0);
    let R = reflect(-V, N);
    let fres = pow(1.0 - saturate(N.z), 3.0);
    let H = normalize(L + V);
    let sp = pow(saturate(dot(N, H)), mix(14.0, 180.0, m.gloss)) * mix(0.12, 1.5, m.gloss);
    col += vec3f(sp);
    let refl = mix(0.03, 0.42, m.gloss) + fres * 0.5;
    col = mix(col, studio(R) * mix(vec3f(1.0), m.albedo * 1.3, m.metal), refl * mix(0.5, 1.0, m.gloss));
    col *= ao;
    col += m.emisColor * m.emis;
    return col;
}
fn sdBox(p: vec2f, b: vec2f, r: f32) -> f32 {
    let d = abs(p) - b + r;
    return length(max(d, vec2f(0.0))) + min(max(d.x, d.y), 0.0) - r;
}
fn groove(d: f32, w: f32) -> f32 { return smoothstep(w, 0.0, abs(d)); }

// ---------- robot ----------
struct RobotU {
    center: vec2f, radius: f32, heading: f32,
    lidar: f32, bumper: f32, binFill: f32, ledPulse: f32,
    led: vec4f,
    alpha: f32, shakeX: f32, shakeY: f32, lift: f32,
};
@group(0) @binding(1) var<uniform> robotU: RobotU;

struct Surf { h: f32, mat: i32, ao: f32 };

fn robotHeight(l: vec2f) -> Surf {
    let r = length(l);
    let ang = atan2(l.y, l.x);
    // Body: a fat rounded shell with a very slight crown.
    let e = saturate((1.0 - r) / 0.14);
    var h = 0.30 * sqrt(1.0 - (1.0 - e) * (1.0 - e)) + 0.035 * (1.0 - r * r);
    var mat = 0;
    var ao = 1.0;

    // Bumper arc wraps the front; it physically moves in when struck.
    let inner = 0.845 - robotU.bumper * 0.018;
    let front = abs(ang) < 1.85;
    let seam = groove(r - inner, 0.012) * select(0.0, 1.0, front);
    let endA = abs(abs(ang) - 1.85) * r;
    let seamEnd = groove(endA, 0.012) * step(inner, r) * step(r, 0.99);
    h -= 0.05 * max(seam, seamEnd);
    ao *= 1.0 - 0.72 * max(seam, seamEnd);
    if (front && r > inner) {
        mat = 1;
        // Dark sensor window along the leading edge.
        if (abs(ang) < 0.72 && r > 0.905 && r < 0.977) { mat = 2; }
    }

    // Graphite top plate, glossy, inset slightly.
    let plate = r - 0.70;
    let plateRim = groove(plate, 0.010);
    if (plate < 0.0) { h -= 0.010; h += 0.085 * (1.0 - (r * r) / (0.70 * 0.70)); mat = 3; }
    ao *= 1.0 - 0.45 * plateRim;

    // Hairline cut for the bin lid at the rear.
    let lidP = l - vec2f(-0.46, 0.0);
    let lid = sdBox(lidP, vec2f(0.135, 0.38), 0.07);
    if (plate < 0.0) { h -= 0.010 * groove(lid, 0.007); ao *= 1.0 - 0.4 * groove(lid, 0.006); }

    // Button pill.
    let pp = l - vec2f(-0.17, 0.0);
    let pill = sdBox(pp, vec2f(0.04, 0.17), 0.04);
    if (pill < 0.0) { mat = 4; h += 0.005; }
    ao *= 1.0 - 0.4 * groove(pill, 0.008);
    let b1 = length(l - vec2f(-0.17, 0.085)) - 0.03;
    let b2 = length(l - vec2f(-0.17, -0.085)) - 0.03;
    if (b1 < 0.0 || b2 < 0.0) { mat = 5; h -= 0.004; }

    // Lidar turret: the one thing that stands proud of the body.
    let tp = l - vec2f(0.27, 0.0);
    let td = length(tp);
    let tR = 0.265;
    let te = saturate((tR - td) / 0.05);
    h += 0.11 * sqrt(1.0 - (1.0 - te) * (1.0 - te));
    if (td < tR) {
        mat = 6;
        if (td < 0.185) { mat = 7; h += 0.045 * (1.0 - td * td / (0.185 * 0.185)); }
    }
    ao *= 1.0 - 0.55 * smoothstep(tR + 0.05, tR, td) * step(tR, td);
    return Surf(h, mat, ao);
}

@vertex fn robotVS(@builtin(vertex_index) vid: u32) -> QuadOut {
    let q = quad(vid) * robotU.radius * 1.03;
    var o: QuadOut;
    o.pos = toClip(robotU.center + q + vec2f(robotU.shakeX, robotU.shakeY));
    o.p = q;
    return o;
}

@fragment fn robotFS(i: QuadOut) -> @location(0) vec4f {
    let u = robotU;
    let wp = i.p / u.radius;
    let rr = length(wp);
    let px = fwidth(i.p.x) / u.radius;
    let edge = smoothstep(1.0, 1.0 - px * 1.5, rr);
    if (edge <= 0.0) { discard; }
    let l = rot(wp, -u.heading);

    let E = 0.0035;
    let s0 = robotHeight(l);
    let hx = robotHeight(l + vec2f(E, 0.0)).h - robotHeight(l - vec2f(E, 0.0)).h;
    let hy = robotHeight(l + vec2f(0.0, E)).h - robotHeight(l - vec2f(0.0, E)).h;
    let gr = vec2f(hx, hy) / (2.0 * E);
    // Back to world space so the light never rotates with the robot.
    let gw = rot(gr, u.heading);
    let N = normalize(vec3f(-gw * 1.05, 1.0));

    var m = Mat(vec3f(0.90, 0.90, 0.88), 0.28, 0.0, 0.0, vec3f(0.0));
    switch (s0.mat) {
        case 1: { m.albedo = vec3f(0.84, 0.84, 0.83); m.gloss = 0.20; }
        case 2: { m.albedo = vec3f(0.018, 0.019, 0.022); m.gloss = 1.0; }
        case 3: { m.albedo = vec3f(0.055, 0.058, 0.065); m.gloss = 0.72; }
        case 4: { m.albedo = vec3f(0.035, 0.035, 0.04); m.gloss = 0.4; }
        case 5: { m.albedo = vec3f(0.72, 0.73, 0.75); m.gloss = 0.5; m.metal = 0.6; }
        case 6: { m.albedo = vec3f(0.62, 0.62, 0.62); m.gloss = 0.16; }
        case 7: { m.albedo = vec3f(0.015, 0.016, 0.02); m.gloss = 1.0; }
        default: {}
    }

    // Spinning laser head, seen through the smoked dome.
    let tp = l - vec2f(0.27, 0.0);
    let td = length(tp);
    var extra = vec3f(0.0);
    if (s0.mat == 7) {
        let gl = vec2f(cos(u.lidar), sin(u.lidar)) * 0.105;
        extra += vec3f(0.45, 0.85, 1.0) * exp(-dot(tp - gl, tp - gl) * 1500.0) * 0.9;
        extra += vec3f(0.45, 0.85, 1.0) * exp(-dot(tp + gl * 0.9, tp + gl * 0.9) * 2600.0) * 0.25;
    }
    // Status ring around the turret.
    let ring = groove(td - 0.225, 0.009);
    let pulse = 0.62 + 0.38 * sin(u.ledPulse * 3.0);
    m.emis = ring * pulse * 1.15;
    m.emisColor = u.led.rgb;
    // Button glyph glow.
    let glow1 = exp(-pow(length(l - vec2f(-0.17, 0.085)) / 0.022, 2.0));
    extra += u.led.rgb * glow1 * 0.5;

    // Logotype on the graphite plate.
    let luv = vec2f((l.y + 0.31) / 0.62, (-l.x - 0.42) / 0.218);
    let la = textureSampleLevel(tex0, linearSampler, luv, 0.0).a;
    if (all(luv > vec2f(0.0)) && all(luv < vec2f(1.0)) && length(l) < 0.70) {
        m.albedo = mix(m.albedo, vec3f(0.62, 0.64, 0.68), la * 0.85);
    }

    var col = shade(N, m, s0.ao) + extra;
    // Grounding: the rim rolls off a touch into its own shadow.
    col *= mix(0.7, 1.0, smoothstep(1.0, 0.90, rr));
    return vec4f(col * edge * u.alpha, edge * u.alpha);
}

// Rotating side brush; blurs into a disc as it speeds up.
struct BrushU { center: vec2f, radius: f32, angle: f32, speed: f32, alpha: f32, sign_: f32, pad: f32 };
@group(0) @binding(1) var<uniform> brushU: BrushU;
@vertex fn brushVS(@builtin(vertex_index) vid: u32) -> QuadOut {
    let q = quad(vid) * brushU.radius;
    var o: QuadOut;
    o.pos = toClip(brushU.center + q);
    o.p = q;
    return o;
}
@fragment fn brushFS(i: QuadOut) -> @location(0) vec4f {
    let u = brushU;
    let p = i.p / u.radius;
    let r = length(p);
    if (r > 1.0) { discard; }
    let a = atan2(p.y, p.x) * u.sign_ - u.angle;
    let blur = saturate(u.speed / 26.0);
    var total = 0.0;
    for (var k = 0; k < 3; k++) {
        // Bristle arms curve backwards against the spin.
        var armA = a + f32(k) * 2.0944 - r * 0.55;
        armA = atan2(sin(armA), cos(armA));
        let w = mix(0.035, 0.46, blur) + 0.07 * (1.0 - r);
        let m = exp(-armA * armA / (w * w));
        let fray = 0.72 + 0.28 * sin(armA * 60.0 + r * 3.0);
        total += m * fray;
    }
    let fade = smoothstep(1.0, 0.78, r);
    let alpha = saturate(total) * fade * mix(0.96, 0.52, blur);
    let hub = smoothstep(0.17, 0.13, r);
    let bristle = mix(vec3f(0.10, 0.10, 0.11), vec3f(0.62, 0.62, 0.66), r * r);
    let col = mix(bristle, vec3f(0.04), hub);
    let aOut = max(alpha, hub) * u.alpha;
    return vec4f(col * aOut, aOut);
}

// Soft drop shadows.
struct ShadowU { center: vec2f, radius: f32, strength: f32, offset: vec2f, blur: f32, kind: f32, halfBox: vec2f, angle: f32, pad: f32 };
@group(0) @binding(1) var<uniform> shadowU: ShadowU;
@vertex fn shadowVS(@builtin(vertex_index) vid: u32) -> QuadOut {
    let u = shadowU;
    var ext = vec2f(u.radius + u.blur * 2.0 + 6.0);
    if (u.kind > 0.5) { ext = u.halfBox + u.blur * 2.0 + 6.0; }
    let q = rot(quad(vid) * ext, u.angle);
    var o: QuadOut;
    o.pos = toClip(u.center + u.offset + q);
    o.p = q;
    return o;
}
@fragment fn shadowFS(i: QuadOut) -> @location(0) vec4f {
    let u = shadowU;
    var d: f32;
    if (u.kind > 0.5) {
        d = sdBox(rot(i.p, -u.angle), u.halfBox, u.radius);
    } else {
        d = length(i.p) - u.radius;
    }
    var a = 1.0 - smoothstep(-u.blur, u.blur, d);
    a = a * a * (3.0 - 2.0 * a);
    return vec4f(0.0, 0.0, 0.0, a * u.strength);
}

// ---------- dock ----------
struct DockU { center: vec2f, half_: vec2f, radius: f32, alpha: f32, bag: f32, glow: f32, ledPulse: f32, p0: f32, p1: f32, p2: f32, led: vec4f };
@group(0) @binding(1) var<uniform> dockU: DockU;
@vertex fn dockVS(@builtin(vertex_index) vid: u32) -> QuadOut {
    let q = quad(vid) * dockU.half_;
    var o: QuadOut;
    o.pos = toClip(dockU.center + q);
    o.p = q;
    return o;
}
fn dockHeight(d: vec2f) -> Surf {
    // d: x sideways, y outward from the back wall, in robot radii, origin at docked robot centre.
    var ao = 1.0;
    var mat = 0;
    let rampD = sdBox(d - vec2f(0.0, -0.20), vec2f(1.14, 0.98), 0.24);
    var h = 0.0;
    if (rampD < 0.0) {
        let e = saturate(-rampD / 0.05);
        h = 0.05 * sqrt(1.0 - (1.0 - e) * (1.0 - e));
        mat = 1;
        // Non-slip ribs fade towards the lip.
        let rib = sin(d.y * 90.0) * smoothstep(0.72, 0.1, d.y) * 0.0022 * smoothstep(-0.06, -0.2, rampD);
        h += rib;
    }
    // Charge contacts.
    let cp = vec2f(abs(d.x) - 0.42, d.y + 0.78);
    let contact = sdBox(cp, vec2f(0.13, 0.04), 0.03);
    if (contact < 0.0 && rampD < 0.0) { mat = 2; h += 0.012; }

    // Tower behind the robot.
    let tc = d - vec2f(0.0, -1.50);
    let tower = sdBox(tc, vec2f(1.26, 0.58), 0.30);
    if (tower < 0.0) {
        let e = saturate(-tower / 0.13);
        h = 0.40 * sqrt(1.0 - (1.0 - e) * (1.0 - e));
        mat = 3;
        // Bag window.
        let win = sdBox(d - vec2f(0.0, -1.50), vec2f(0.76, 0.29), 0.11);
        if (win < 0.0) { mat = 4; h = 0.34; }
        ao *= 1.0 - 0.6 * groove(win, 0.014);
        // Vents at each end.
        let vp = vec2f(abs(d.x) - 1.05, d.y + 1.50);
        if (abs(vp.x) < 0.09 && abs(vp.y) < 0.26) {
            let slit = smoothstep(0.2, 0.7, sin(vp.y * 62.0));
            h -= 0.014 * slit;
            ao *= 1.0 - 0.55 * slit;
        }
    }
    ao *= 1.0 - 0.5 * groove(tower, 0.02);
    return Surf(h, mat, ao);
}
@fragment fn dockFS(i: QuadOut) -> @location(0) vec4f {
    let u = dockU;
    // Dock faces up the screen: outward = -y.
    let d = vec2f(i.p.x, -i.p.y) / u.radius;
    let E = 0.004;
    let s0 = dockHeight(d);
    let hx = dockHeight(d + vec2f(E, 0.0)).h - dockHeight(d - vec2f(E, 0.0)).h;
    let hy = dockHeight(d + vec2f(0.0, E)).h - dockHeight(d - vec2f(0.0, E)).h;
    let luv = vec2f((d.x + 0.34) / 0.68, (d.y + 2.03 - 0.04) / 0.19);
    let la = textureSampleLevel(tex0, linearSampler, vec2f(luv.x, 1.0 - luv.y), 0.0).a;
    if (s0.h <= 0.0001) { discard; }
    let gr = vec2f(hx, -hy) / (2.0 * E);
    let N = normalize(vec3f(-gr, 1.0));
    var m = Mat(vec3f(0.9, 0.9, 0.88), 0.3, 0.0, 0.0, vec3f(0.0));
    var extra = vec3f(0.0);
    if (s0.mat == 1) { m.albedo = vec3f(0.10, 0.105, 0.115); m.gloss = 0.18; }
    if (s0.mat == 2) { m.albedo = vec3f(0.95, 0.78, 0.42); m.gloss = 0.85; m.metal = 1.0; }
    if (s0.mat == 4) {
        // Dust bag behind smoked glass: a pillow that grows and glows as it fills.
        let w = d - vec2f(0.0, -1.50);
        let fill = u.bag;
        let bx = 0.72 * (0.3 + 0.7 * sqrt(fill));
        let bag = sdBox(w, vec2f(bx, 0.25), 0.10);
        let inside = smoothstep(0.01, -0.01, bag);
        let puff = sqrt(saturate(-bag / 0.13));
        let base = vec3f(0.04, 0.045, 0.05);
        let wr = sin(w.x * 21.0 + w.y * 11.0) * sin(w.y * 37.0 - w.x * 9.0);
        let bagc = mix(vec3f(0.34, 0.36, 0.39), vec3f(0.72, 0.73, 0.74), puff) * (1.0 + 0.04 * wr);
        m.albedo = mix(base, bagc, inside * 0.85);
        m.gloss = 0.9;
        extra += vec3f(0.25, 0.6, 0.9) * u.glow * 0.24 * (0.3 + inside);
    }
    // LED strip along the tower's front edge.
    let lp = d - vec2f(0.0, -0.98);
    if (abs(lp.x) < 0.34 && abs(lp.y) < 0.016) {
        m.emis = (0.65 + 0.35 * sin(u.ledPulse * 2.4)) * 1.1;
        m.emisColor = u.led.rgb;
    }
    var col = shade(N, m, s0.ao) + extra;
    if (all(luv > vec2f(0.0)) && all(luv < vec2f(1.0))) {
        col = mix(col, vec3f(0.32, 0.33, 0.35), la * 0.85);
    }
    let a = u.alpha * smoothstep(0.0, 0.012, s0.h);
    return vec4f(col * a, a);
}

// ---------- lidar sweep ----------
struct LidarU { center: vec2f, radius: f32, angle: f32, alpha: f32, p0: f32, p1: f32, p2: f32 };
@group(0) @binding(1) var<uniform> lidarU: LidarU;
@vertex fn lidarVS(@builtin(vertex_index) vid: u32) -> QuadOut {
    let q = quad(vid) * lidarU.radius;
    var o: QuadOut;
    o.pos = toClip(lidarU.center + q);
    o.p = q;
    return o;
}
@fragment fn lidarFS(i: QuadOut) -> @location(0) vec4f {
    let u = lidarU;
    let r = length(i.p) / u.radius;
    if (r > 1.0) { discard; }
    var a = atan2(i.p.y, i.p.x) - u.angle;
    // Radians behind the beam (Metal's fmod truncates; the argument is always positive here).
    let x = -a + 62.83185 * 4.0;
    a = x - 6.283185 * floor(x / 6.283185);
    let tail = exp(-a * 2.4) * 0.26;
    let line = exp(-a * a * 1800.0) * 0.55;
    let rings = smoothstep(0.012, 0.0, abs(fract(r * 9.0) - 0.5) / 9.0) * 0.05 * exp(-a * 1.2);
    let fall = pow(1.0 - r, 0.35);
    let k = (tail + line + rings) * fall * u.alpha;
    let c = vec3f(0.32, 0.86, 1.0);
    return vec4f(c * k, k * 0.55);
}
