use crate::math::{SeededRng, V2, clampf, v2};
use std::path::PathBuf;
use std::time::SystemTime;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Folder,
    Image,
    Video,
    Document,
    Archive,
    Audio,
    Other,
}

impl Kind {
    pub const ALL: [Kind; 7] = [
        Kind::Folder,
        Kind::Image,
        Kind::Video,
        Kind::Document,
        Kind::Archive,
        Kind::Audio,
        Kind::Other,
    ];

    #[cfg_attr(not(windows), allow(dead_code))]
    pub fn of_name(name: &str, is_dir: bool) -> Kind {
        if is_dir {
            return Kind::Folder;
        }
        let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
        match ext.as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "bmp" | "webp" | "heic" | "heif" | "tif" | "tiff" | "svg" | "ico" | "raw" | "psd" => {
                Kind::Image
            }
            "mp4" | "mov" | "mkv" | "avi" | "wmv" | "webm" | "m4v" | "flv" => Kind::Video,
            "mp3" | "m4a" | "wav" | "flac" | "ogg" | "aac" | "wma" | "opus" => Kind::Audio,
            "zip" | "7z" | "rar" | "tar" | "gz" | "bz2" | "xz" | "zst" | "iso" | "cab" => Kind::Archive,
            "pdf" | "txt" | "md" | "rtf" | "doc" | "docx" | "odt" | "xls" | "xlsx" | "ods" | "csv" | "ppt" | "pptx" | "odp" | "json"
            | "xml" | "html" | "htm" | "log" => Kind::Document,
            _ => Kind::Other,
        }
    }
}

/// One thing on the desktop, as far as drawing is concerned. Holds nothing that can change a file.
#[derive(Clone)]
pub struct DesktopEntry {
    pub name: String,
    /// Icon centre, top-left origin, monitor-local logical pixels.
    pub center: V2,
    pub bytes: i64,
    pub kind: Kind,
    /// None for sample items.
    pub path: Option<PathBuf>,
    /// Sample items carry their picture (RGBA, straight alpha).
    pub image: Option<image::RgbaImage>,
    pub modified: Option<SystemTime>,
    /// Trash and Delete leave these alone.
    pub protected_reason: Option<String>,
    /// Shown on the desktop but not a file in the user's Desktop folder, such as This PC.
    pub missing: bool,
    /// Lives in OneDrive's Desktop folder, so deleting it also removes it from other devices.
    pub cloud: bool,
    /// Shell parsing name for items with no file behind them (the Recycle Bin is
    /// `::{645FF040-…}`), so their real icon can still be fetched.
    #[cfg_attr(not(windows), allow(dead_code))]
    pub shell_id: Option<String>,
}

impl DesktopEntry {
    pub fn sample(name: &str, center: V2, bytes: i64, kind: Kind, image: Option<image::RgbaImage>) -> Self {
        DesktopEntry {
            name: name.into(),
            center,
            bytes,
            kind,
            path: None,
            image,
            modified: None,
            protected_reason: None,
            missing: false,
            cloud: false,
            shell_id: None,
        }
    }
}

/// A believable mess that contains nothing of the user's. Same code path after this point.
pub fn sample(w: f32, h: f32) -> Vec<DesktopEntry> {
    let mut rng = SeededRng::new(20261101);
    let specs: &[(&str, Kind, i64)] = &[
        ("final-final-v2.pdf", Kind::Document, 2_400_000),
        ("meeting-that-could-be-an-email.txt", Kind::Document, 3_000),
        ("Screenshot 2026-10-12 091422.png", Kind::Image, 900_000),
        ("Screenshot 2026-10-12 091431.png", Kind::Image, 880_000),
        ("Screenshot 2026-10-14 170211.png", Kind::Image, 1_400_000),
        ("Screenshot 2026-10-19 114708.png", Kind::Image, 760_000),
        ("Screenshot 2026-10-21 223051.png", Kind::Image, 1_100_000),
        ("Screenshot 2026-10-28 080540.png", Kind::Image, 650_000),
        ("Screen Recording 2026-10-30 145030.mp4", Kind::Video, 4_200_000_000),
        ("weekend-take-12.mov", Kind::Video, 2_100_000_000),
        ("demo-for-nobody.mp4", Kind::Video, 880_000_000),
        ("backup-of-the-backup.zip", Kind::Archive, 6_300_000_000),
        ("old-site.zip", Kind::Archive, 310_000_000),
        ("taxes-2023.zip", Kind::Archive, 44_000_000),
        ("budget-snacks.xlsx", Kind::Document, 90_000),
        ("q3-slides-actually-final.pptx", Kind::Document, 38_000_000),
        ("do-not-delete", Kind::Folder, 900_000_000),
        ("to-delete-later", Kind::Folder, 120_000_000),
        ("desktop-cleaning", Kind::Folder, 40_000_000),
        ("icons", Kind::Folder, 15_000_000),
        ("misc", Kind::Folder, 80_000_000),
        ("misc (2)", Kind::Folder, 60_000_000),
        ("New folder", Kind::Folder, 0),
        ("three-dollar-song.mp3", Kind::Audio, 7_000_000),
        ("voice-memo-idea.m4a", Kind::Audio, 3_000_000),
        ("IMG_2041.jpg", Kind::Image, 3_800_000),
        ("IMG_2042.jpg", Kind::Image, 3_600_000),
        ("IMG_2043.jpg", Kind::Image, 4_100_000),
        ("blurry-pigeon.heic", Kind::Image, 2_200_000),
        ("coffee-receipt.jpg", Kind::Image, 400_000),
        ("logo-new-NEW.png", Kind::Image, 300_000),
        ("logo-old.png", Kind::Image, 220_000),
        ("notes.txt", Kind::Document, 1_000),
        ("notes - Copy.txt", Kind::Document, 1_000),
        ("notes - Copy (2).txt", Kind::Document, 1_000),
        ("invoice-sample.pdf", Kind::Document, 120_000),
        ("resume_v14.pdf", Kind::Document, 210_000),
        ("ergonomic-chair.pdf", Kind::Document, 3_100_000),
        ("New Text Document.txt", Kind::Document, 12),
        ("New Text Document (2).txt", Kind::Document, 40),
        ("wallpaper-idea.png", Kind::Image, 5_400_000),
        ("mood-board.png", Kind::Image, 8_100_000),
    ];
    let mut out = Vec::new();
    // A tidy Explorer column on the left, a dense pile in the middle, stragglers everywhere else.
    for (i, (name, kind, bytes)) in specs.iter().enumerate() {
        let bucket = i % 5;
        let mut c = if bucket == 0 {
            let col = ((i / 5) / 6) as f32;
            let row = ((i / 5) % 6) as f32;
            v2(46.0 + col * 84.0, 60.0 + row * 96.0)
        } else if bucket == 4 {
            v2(rng.range(120.0, w - 120.0), rng.range(110.0, h - 300.0))
        } else {
            let a = rng.range(0.0, std::f32::consts::TAU);
            let d = rng.range(0.25, 1.0) * rng.range(170.0, 420.0);
            v2(w * 0.52 + a.cos() * d * 1.5, h * 0.42 + a.sin() * d)
        };
        c.x = clampf(c.x, 46.0, w - 60.0);
        c.y = clampf(c.y, 50.0, h - 170.0);
        let img = (*kind == Kind::Image).then(|| crate::sprites::sample_thumbnail(i as u64, name.starts_with("Screenshot")));
        out.push(DesktopEntry::sample(name, c, *bytes, *kind, img));
    }
    out
}
