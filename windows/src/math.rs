use std::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, bytemuck::Pod, bytemuck::Zeroable)]
pub struct V2 {
    pub x: f32,
    pub y: f32,
}

pub const fn v2(x: f32, y: f32) -> V2 {
    V2 { x, y }
}

impl V2 {
    pub const ZERO: V2 = v2(0.0, 0.0);
    pub fn len(self) -> f32 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
    pub fn unit(self) -> V2 {
        let l = self.len();
        if l > 1e-5 { self / l } else { V2::ZERO }
    }
    pub fn perp(self) -> V2 {
        v2(-self.y, self.x)
    }
    pub fn dot(self, o: V2) -> f32 {
        self.x * o.x + self.y * o.y
    }
    pub fn rotated(self, a: f32) -> V2 {
        let (s, c) = a.sin_cos();
        v2(c * self.x - s * self.y, s * self.x + c * self.y)
    }
}

impl Add for V2 {
    type Output = V2;
    fn add(self, o: V2) -> V2 {
        v2(self.x + o.x, self.y + o.y)
    }
}
impl Sub for V2 {
    type Output = V2;
    fn sub(self, o: V2) -> V2 {
        v2(self.x - o.x, self.y - o.y)
    }
}
impl Mul<f32> for V2 {
    type Output = V2;
    fn mul(self, k: f32) -> V2 {
        v2(self.x * k, self.y * k)
    }
}
impl Div<f32> for V2 {
    type Output = V2;
    fn div(self, k: f32) -> V2 {
        v2(self.x / k, self.y / k)
    }
}
impl Neg for V2 {
    type Output = V2;
    fn neg(self) -> V2 {
        v2(-self.x, -self.y)
    }
}
impl AddAssign for V2 {
    fn add_assign(&mut self, o: V2) {
        self.x += o.x;
        self.y += o.y;
    }
}
impl SubAssign for V2 {
    fn sub_assign(&mut self, o: V2) {
        self.x -= o.x;
        self.y -= o.y;
    }
}
impl MulAssign<f32> for V2 {
    fn mul_assign(&mut self, k: f32) {
        self.x *= k;
        self.y *= k;
    }
}

pub fn clampf(v: f32, a: f32, b: f32) -> f32 {
    v.max(a).min(b)
}

pub fn smooth(a: f32, b: f32, x: f32) -> f32 {
    let t = clampf((x - a) / (b - a), 0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

pub fn wrap_angle(a: f32) -> f32 {
    use std::f32::consts::PI;
    let mut x = a;
    while x > PI {
        x -= 2.0 * PI;
    }
    while x < -PI {
        x += 2.0 * PI;
    }
    x
}

/// Small xorshift generator, so a run looks the same every time.
#[derive(Clone)]
pub struct SeededRng(u64);

impl SeededRng {
    pub fn new(seed: u64) -> Self {
        SeededRng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next_u64(&mut self) -> u64 {
        let mut s = self.0;
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        self.0 = s;
        s
    }
    /// Uniform in [0, 1].
    pub fn unit(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / ((1u64 << 24) - 1) as f32
    }
    pub fn range(&mut self, a: f32, b: f32) -> f32 {
        a + (b - a) * self.unit()
    }
}
