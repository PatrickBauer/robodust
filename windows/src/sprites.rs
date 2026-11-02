//! Turns entries into two bitmaps each (icon + label), drawn to match the Windows desktop.

use crate::entries::{DesktopEntry, Kind};
use crate::math::SeededRng;
use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use image::{Rgba, RgbaImage, imageops};
use std::sync::OnceLock;

/// Logical sizes of one desktop icon cell (medium icons, 100 % scaling).
pub const ICON_PTS: f32 = 48.0;
pub const LABEL_W: f32 = 78.0;
pub const LABEL_H: f32 = 34.0;
/// Label centre below the icon centre.
pub const LABEL_OFFSET: f32 = ICON_PTS / 2.0 + 2.0 + LABEL_H / 2.0;
/// Sprites are rasterised at this many pixels per logical pixel.
pub const SCALE: f32 = 2.0;

pub struct Sprite {
    /// Premultiplied RGBA.
    pub icon: RgbaImage,
    pub label: RgbaImage,
    pub average: [f32; 3],
}

pub fn icon_px() -> u32 {
    (ICON_PTS * SCALE) as u32
}
pub fn label_px() -> (u32, u32) {
    ((LABEL_W * SCALE) as u32, (LABEL_H * SCALE) as u32)
}

// MARK: - Fonts

pub struct Fonts {
    pub regular: FontVec,
    pub semibold: FontVec,
}

/// The first candidate that loads, with its bytes (FontVec can't be cloned).
fn load_font_bytes(candidates: &[String]) -> Option<(FontVec, Vec<u8>)> {
    candidates.iter().find_map(|p| {
        std::fs::read(p)
            .ok()
            .and_then(|b| FontVec::try_from_vec(b.clone()).ok().map(|f| (f, b)))
    })
}

/// A font file in the Windows font folder, wherever Windows is installed.
fn windows_font(file: &str) -> String {
    let dir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
    format!("{dir}\\Fonts\\{file}")
}

fn paths(windows: &[&str], others: &[&str]) -> Vec<String> {
    windows
        .iter()
        .map(|f| windows_font(f))
        .chain(others.iter().map(|p| p.to_string()))
        .collect()
}

pub fn fonts() -> &'static Fonts {
    static F: OnceLock<Fonts> = OnceLock::new();
    F.get_or_init(|| {
        let (regular, regular_bytes) = load_font_bytes(&paths(
            &["segoeui.ttf", "arial.ttf"],
            &[
                "/usr/share/fonts/noto/NotoSans-Regular.ttf",
                "/usr/share/fonts/TTF/DejaVuSans.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/Library/Fonts/Arial Unicode.ttf",
            ],
        ))
        .expect("no usable font found");
        // No bold face around: the regular one stands in.
        let semibold = load_font_bytes(&paths(
            &["seguisb.ttf", "segoeuib.ttf", "arialbd.ttf"],
            &[
                "/usr/share/fonts/noto/NotoSans-SemiBold.ttf",
                "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            ],
        ))
        .map(|(f, _)| f)
        .unwrap_or_else(|| FontVec::try_from_vec(regular_bytes).expect("font loaded once already"));
        Fonts { regular, semibold }
    })
}

pub fn text_width(font: &FontVec, px: f32, s: &str) -> f32 {
    let f = font.as_scaled(PxScale::from(px));
    let mut w = 0.0;
    let mut prev = None;
    for c in s.chars() {
        let g = f.glyph_id(c);
        if let Some(p) = prev {
            w += f.kern(p, g);
        }
        w += f.h_advance(g);
        prev = Some(g);
    }
    w
}

/// Draws text as coverage into an alpha mask (one f32 per pixel), baseline at `y`.
#[allow(clippy::too_many_arguments)]
pub fn draw_text_mask(mask: &mut [f32], w: u32, h: u32, font: &FontVec, px: f32, s: &str, x: f32, y: f32, tracking: f32) {
    let f = font.as_scaled(PxScale::from(px));
    let mut pen = x;
    let mut prev = None;
    for c in s.chars() {
        let id = f.glyph_id(c);
        if let Some(p) = prev {
            pen += f.kern(p, id);
        }
        let g = id.with_scale_and_position(PxScale::from(px), ab_glyph::point(pen, y));
        if let Some(o) = font.outline_glyph(g) {
            let b = o.px_bounds();
            o.draw(|gx, gy, cov| {
                let xx = b.min.x as i32 + gx as i32;
                let yy = b.min.y as i32 + gy as i32;
                if xx >= 0 && yy >= 0 && (xx as u32) < w && (yy as u32) < h {
                    let i = (yy as u32 * w + xx as u32) as usize;
                    mask[i] = (mask[i] + cov).min(1.0);
                }
            });
        }
        pen += f.h_advance(id) + tracking;
        prev = Some(id);
    }
}

fn blur_mask(mask: &[f32], w: u32, h: u32, radius: i32) -> Vec<f32> {
    if radius <= 0 {
        return mask.to_vec();
    }
    let (w, h) = (w as i32, h as i32);
    let mut tmp = vec![0.0; mask.len()];
    let mut out = vec![0.0; mask.len()];
    let n = (2 * radius + 1) as f32;
    for y in 0..h {
        for x in 0..w {
            let mut s = 0.0;
            for k in -radius..=radius {
                let xx = (x + k).clamp(0, w - 1);
                s += mask[(y * w + xx) as usize];
            }
            tmp[(y * w + x) as usize] = s / n;
        }
    }
    for y in 0..h {
        for x in 0..w {
            let mut s = 0.0;
            for k in -radius..=radius {
                let yy = (y + k).clamp(0, h - 1);
                s += tmp[(yy * w + x) as usize];
            }
            out[(y * w + x) as usize] = s / n;
        }
    }
    out
}

// MARK: - Painting helpers (straight alpha in, straight alpha out)

fn blend(dst: &mut Rgba<u8>, c: [f32; 4]) {
    let a = c[3].clamp(0.0, 1.0);
    if a <= 0.0 {
        return;
    }
    let da = dst[3] as f32 / 255.0;
    let oa = a + da * (1.0 - a);
    for i in 0..3 {
        let d = dst[i] as f32 / 255.0;
        let o = if oa > 0.0 { (c[i] * a + d * da * (1.0 - a)) / oa } else { 0.0 };
        dst[i] = (o * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    dst[3] = (oa * 255.0).round() as u8;
}

pub fn fill_rect(img: &mut RgbaImage, x: f32, y: f32, w: f32, h: f32, c: [f32; 4]) {
    let (iw, ih) = img.dimensions();
    let x0 = x.max(0.0) as u32;
    let y0 = y.max(0.0) as u32;
    let x1 = ((x + w).min(iw as f32)).max(0.0) as u32;
    let y1 = ((y + h).min(ih as f32)).max(0.0) as u32;
    for yy in y0..y1 {
        for xx in x0..x1 {
            blend(img.get_pixel_mut(xx, yy), c);
        }
    }
}

pub fn fill_ellipse(img: &mut RgbaImage, cx: f32, cy: f32, rx: f32, ry: f32, c: [f32; 4]) {
    let (iw, ih) = img.dimensions();
    let x0 = (cx - rx - 1.0).max(0.0) as u32;
    let x1 = ((cx + rx + 1.0).min(iw as f32)).max(0.0) as u32;
    let y0 = (cy - ry - 1.0).max(0.0) as u32;
    let y1 = ((cy + ry + 1.0).min(ih as f32)).max(0.0) as u32;
    for yy in y0..y1 {
        for xx in x0..x1 {
            let dx = (xx as f32 + 0.5 - cx) / rx;
            let dy = (yy as f32 + 0.5 - cy) / ry;
            let d = (dx * dx + dy * dy).sqrt();
            let cov = ((1.0 - d) * rx.min(ry)).clamp(0.0, 1.0);
            if cov > 0.0 {
                blend(img.get_pixel_mut(xx, yy), [c[0], c[1], c[2], c[3] * cov]);
            }
        }
    }
}

fn fill_round_rect(img: &mut RgbaImage, x: f32, y: f32, w: f32, h: f32, r: f32, c: [f32; 4]) {
    let (iw, ih) = img.dimensions();
    for yy in (y.max(0.0) as u32)..((y + h).min(ih as f32) as u32) {
        for xx in (x.max(0.0) as u32)..((x + w).min(iw as f32) as u32) {
            let px = xx as f32 + 0.5 - (x + w / 2.0);
            let py = yy as f32 + 0.5 - (y + h / 2.0);
            let qx = px.abs() - (w / 2.0 - r);
            let qy = py.abs() - (h / 2.0 - r);
            let d = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt() + qx.max(qy).min(0.0) - r;
            let cov = (0.5 - d).clamp(0.0, 1.0);
            if cov > 0.0 {
                blend(img.get_pixel_mut(xx, yy), [c[0], c[1], c[2], c[3] * cov]);
            }
        }
    }
}

fn lerp3(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
}

/// Scales `src` to fit inside the box and draws it there.
fn draw_fit(dst: &mut RgbaImage, src: &RgbaImage, bx: f32, by: f32, bw: f32, bh: f32) -> (f32, f32, f32, f32) {
    let k = (bw / src.width() as f32).min(bh / src.height() as f32);
    let w = (src.width() as f32 * k).round().max(1.0);
    let h = (src.height() as f32 * k).round().max(1.0);
    let x = (bx + (bw - w) / 2.0).round();
    let y = (by + (bh - h) / 2.0).round();
    let scaled = imageops::resize(src, w as u32, h as u32, imageops::FilterType::Triangle);
    for (sx, sy, p) in scaled.enumerate_pixels() {
        let dx = x as i64 + sx as i64;
        let dy = y as i64 + sy as i64;
        if dx >= 0 && dy >= 0 && (dx as u32) < dst.width() && (dy as u32) < dst.height() {
            let c = [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0, p[3] as f32 / 255.0];
            blend(dst.get_pixel_mut(dx as u32, dy as u32), c);
        }
    }
    (x, y, w, h)
}

fn premultiply(img: &mut RgbaImage) {
    for p in img.pixels_mut() {
        let a = p[3] as u32;
        for i in 0..3 {
            p[i] = ((p[i] as u32 * a + 127) / 255) as u8;
        }
    }
}

// MARK: - Sample pictures and generic icons

pub fn sample_thumbnail(seed: u64, tall: bool) -> RgbaImage {
    let mut rng = SeededRng::new(seed + 91);
    let (w, h) = (256u32, if tall { 170u32 } else { 200u32 });
    let mut col = || [rng.range(0.15, 0.95), rng.range(0.2, 0.9), rng.range(0.2, 0.95)];
    let (c0, c1, c2) = (col(), col(), col());
    let mut img = RgbaImage::new(w, h);
    for (x, y, p) in img.enumerate_pixels_mut() {
        // Diagonal gradient through three stops.
        let t = ((x as f32 / w as f32) * w as f32 * w as f32 + (y as f32 / h as f32) * h as f32 * h as f32)
            / (w as f32 * w as f32 + h as f32 * h as f32);
        let c = if t < 0.55 {
            lerp3(c0, c1, t / 0.55)
        } else {
            lerp3(c1, c2, (t - 0.55) / 0.45)
        };
        *p = Rgba([(c[0] * 255.0) as u8, (c[1] * 255.0) as u8, (c[2] * 255.0) as u8, 255]);
    }
    if tall {
        // A screenshot of a window: white page, a title bar, some lines of text.
        fill_rect(&mut img, 18.0, 18.0, w as f32 - 36.0, h as f32 - 36.0, [0.98, 0.98, 0.98, 1.0]);
        fill_rect(&mut img, 18.0, 18.0, w as f32 - 36.0, 24.0, [0.82, 0.82, 0.82, 1.0]);
        for i in 0..5 {
            let lw = 80.0 + rng.range(0.0, 90.0);
            fill_rect(&mut img, 34.0, 56.0 + i as f32 * 18.0, lw, 8.0, [0.72, 0.72, 0.72, 1.0]);
        }
    } else {
        for _ in 0..6 {
            let c = [rng.range(0.15, 0.95), rng.range(0.2, 0.9), rng.range(0.2, 0.95), 0.5];
            let d = rng.range(40.0, 120.0);
            let x = rng.range(-20.0, 220.0);
            let y = rng.range(-20.0, 170.0);
            fill_ellipse(&mut img, x + d / 2.0, y + d / 2.0, d / 2.0, d / 2.0, c);
        }
    }
    img
}

/// A stand-in icon for systems without Explorer's icons (development on Linux).
pub fn generic_icon(kind: Kind, name: &str, px: u32) -> RgbaImage {
    let mut img = RgbaImage::new(px, px);
    let s = px as f32;
    match kind {
        Kind::Folder => {
            fill_round_rect(&mut img, s * 0.08, s * 0.2, s * 0.4, s * 0.2, s * 0.04, [0.93, 0.72, 0.25, 1.0]);
            fill_round_rect(&mut img, s * 0.08, s * 0.28, s * 0.84, s * 0.56, s * 0.05, [0.98, 0.80, 0.33, 1.0]);
            fill_rect(&mut img, s * 0.08, s * 0.36, s * 0.84, s * 0.02, [1.0, 0.9, 0.55, 1.0]);
        }
        _ => {
            let band = match kind {
                Kind::Image => [0.2, 0.6, 0.95, 1.0],
                Kind::Video => [0.85, 0.25, 0.35, 1.0],
                Kind::Audio => [0.95, 0.45, 0.2, 1.0],
                Kind::Archive => [0.55, 0.4, 0.85, 1.0],
                Kind::Document => {
                    let ext = name.rsplit_once('.').map(|p| p.1.to_ascii_lowercase()).unwrap_or_default();
                    match ext.as_str() {
                        "pdf" => [0.86, 0.15, 0.15, 1.0],
                        "xlsx" | "xls" | "csv" => [0.12, 0.55, 0.3, 1.0],
                        "pptx" | "ppt" => [0.85, 0.35, 0.15, 1.0],
                        "docx" | "doc" => [0.17, 0.35, 0.75, 1.0],
                        _ => [0.6, 0.6, 0.62, 1.0],
                    }
                }
                _ => [0.5, 0.5, 0.52, 1.0],
            };
            fill_rect(&mut img, s * 0.2 + 2.0, s * 0.1 + 3.0, s * 0.6, s * 0.8, [0.0, 0.0, 0.0, 0.25]);
            fill_rect(&mut img, s * 0.2, s * 0.1, s * 0.6, s * 0.8, [1.0, 1.0, 1.0, 1.0]);
            fill_rect(&mut img, s * 0.2, s * 0.62, s * 0.6, s * 0.16, band);
            for i in 0..4 {
                fill_rect(
                    &mut img,
                    s * 0.28,
                    s * 0.2 + i as f32 * s * 0.08,
                    s * 0.44,
                    s * 0.03,
                    [0.78, 0.78, 0.8, 1.0],
                );
            }
        }
    }
    img
}

// MARK: - Sprites

/// `system_icon` is what Explorer would show (icon or thumbnail), when the platform can supply it.
pub fn make(e: &DesktopEntry, system_icon: Option<RgbaImage>) -> Sprite {
    let px = icon_px();
    let mut icon = RgbaImage::new(px, px);
    let s = px as f32;
    if let Some(src) = &e.image {
        // Sample pictures get a thin white border and a soft shadow, like a thumbnail.
        let inset = s * 0.06;
        let k = ((s - 2.0 * inset) / src.width() as f32).min((s - 2.0 * inset) / src.height() as f32);
        let (w, h) = (src.width() as f32 * k, src.height() as f32 * k);
        let (x, y) = ((s - w) / 2.0, (s - h) / 2.0);
        let mut shadow = vec![0.0f32; (px * px) as usize];
        for yy in (y as u32)..((y + h) as u32 + 3).min(px) {
            for xx in (x as u32)..((x + w) as u32).min(px) {
                shadow[(yy * px + xx) as usize] = 1.0;
            }
        }
        let shadow = blur_mask(&shadow, px, px, 3);
        for (i, p) in icon.pixels_mut().enumerate() {
            *p = Rgba([0, 0, 0, (shadow[i] * 0.4 * 255.0) as u8]);
        }
        fill_rect(&mut icon, x - 3.0, y - 3.0, w + 6.0, h + 6.0, [1.0, 1.0, 1.0, 1.0]);
        draw_fit(&mut icon, src, x, y, w, h);
    } else {
        let src = system_icon.unwrap_or_else(|| generic_icon(e.kind, &e.name, px));
        draw_fit(&mut icon, &src, 0.0, 0.0, s, s);
    }
    let average = average(&icon);
    premultiply(&mut icon);
    Sprite {
        icon,
        label: label(&e.name),
        average,
    }
}

fn average(img: &RgbaImage) -> [f32; 3] {
    let (mut r, mut g, mut b, mut a) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
    for p in img.pixels() {
        let al = p[3] as f64;
        r += p[0] as f64 * al;
        g += p[1] as f64 * al;
        b += p[2] as f64 * al;
        a += al;
    }
    if a <= 0.0 {
        return [0.6, 0.6, 0.6];
    }
    [(r / a / 255.0) as f32, (g / a / 255.0) as f32, (b / a / 255.0) as f32]
}

/// Two lines at most, word-wrapped, the second one ending in an ellipsis: how Explorer labels look.
pub fn label(name: &str) -> RgbaImage {
    let (w, h) = label_px();
    let font = &fonts().regular;
    // Explorer uses 9 pt (12 px em). ab_glyph scales by line height, not em, so convert.
    let px = 12.0 * SCALE * font.height_unscaled() / font.units_per_em().unwrap_or(1000.0);
    let max_w = (LABEL_W - 4.0) * SCALE;
    let lines = wrap(name, max_w, |s| text_width(font, px, s));
    let mut mask = vec![0.0f32; (w * h) as usize];
    let line_h = 15.0 * SCALE;
    let ascent = font.as_scaled(PxScale::from(px)).ascent();
    let mut y = 1.0 * SCALE + ascent;
    for l in &lines {
        let lw = text_width(font, px, l);
        draw_text_mask(&mut mask, w, h, font, px, l, ((w as f32 - lw) / 2.0).round(), y.round(), 0.0);
        y += line_h;
    }
    // Explorer draws white text over a tight dark shadow, offset down and right. Its text also reads
    // heavier than plain coverage (gamma-boosted, and drawn at 1x), so the mask is thickened a little.
    for m in mask.iter_mut() {
        *m = m.powf(0.6);
    }
    let shadow = blur_mask(&mask, w, h, SCALE as i32);
    let mut img = RgbaImage::new(w, h);
    let off = SCALE as i32;
    for yy in 0..h as i32 {
        for xx in 0..w as i32 {
            let sx = (xx - off).clamp(0, w as i32 - 1);
            let sy = (yy - off).clamp(0, h as i32 - 1);
            let sa = (shadow[(sy * w as i32 + sx) as usize] * 2.4).min(1.0) * 0.9;
            let ta = mask[(yy * w as i32 + xx) as usize];
            let p = img.get_pixel_mut(xx as u32, yy as u32);
            *p = Rgba([0, 0, 0, 0]);
            blend(p, [0.0, 0.0, 0.0, sa]);
            blend(p, [1.0, 1.0, 1.0, ta]);
        }
    }
    premultiply(&mut img);
    img
}

pub fn wrap(text: &str, width: f32, measure: impl Fn(&str) -> f32) -> Vec<String> {
    if measure(text) <= width {
        return vec![text.to_string()];
    }
    // First line: longest prefix that fits, preferring a break after a separator.
    let chars: Vec<char> = text.chars().collect();
    let mut fit = 0;
    while fit < chars.len() && measure(&chars[..=fit].iter().collect::<String>()) <= width {
        fit += 1;
    }
    let mut cut = fit.max(1);
    if let Some(br) = (1..fit.max(2)).rev().find(|&i| " -_.".contains(chars[i - 1]))
        && br > fit / 3
    {
        cut = br;
    }
    let first: String = chars[..cut].iter().collect::<String>().trim().to_string();
    let rest: String = chars[cut..].iter().collect();
    if measure(&rest) <= width {
        return vec![first, rest];
    }
    // Second line: as much as fits, then an ellipsis.
    let r: Vec<char> = rest.chars().collect();
    let mut keep = r.len();
    while keep > 0 {
        let s: String = r[..keep].iter().collect::<String>() + "…";
        if measure(&s) <= width {
            return vec![first, s];
        }
        keep -= 1;
    }
    vec![first, "…".into()]
}

/// The "robodust" wordmark that sits on the robot's plate and the dock (alpha only matters).
pub fn logo() -> RgbaImage {
    let (w, h) = (512u32, 180u32);
    let font = &fonts().semibold;
    let px = 92.0;
    let tracking = 4.0;
    let text = "robodust";
    let tw = text_width(font, px, text) + tracking * (text.chars().count() as f32 - 1.0);
    let sf = font.as_scaled(PxScale::from(px));
    let mut mask = vec![0.0f32; (w * h) as usize];
    let base = (h as f32 + sf.ascent() + sf.descent()) / 2.0;
    draw_text_mask(&mut mask, w, h, font, px, text, (w as f32 - tw) / 2.0, base, tracking);
    let mut img = RgbaImage::new(w, h);
    for (i, p) in img.pixels_mut().enumerate() {
        let a = (mask[i] * 255.0) as u8;
        *p = Rgba([a, a, a, a]);
    }
    img
}
