//! What differs between Windows (the real target) and other systems (development only: sample mess).
// Off Windows most of this is never read: the stubs only run the sample mess.
#![cfg_attr(not(windows), allow(dead_code))]

use crate::math::V2;
use std::path::PathBuf;
use std::time::SystemTime;

#[derive(Clone, Copy, Debug)]
pub struct Screen {
    /// Work area (screen minus taskbar) and whole monitor, in physical pixels: x, y, w, h.
    pub work: (i32, i32, u32, u32),
    pub monitor: (i32, i32, u32, u32),
    /// Physical pixels per logical pixel.
    pub scale: f32,
}

impl Screen {
    pub fn logical_size(&self) -> V2 {
        crate::math::v2(self.work.2 as f32 / self.scale, self.work.3 as f32 / self.scale)
    }
    /// Logical point inside the work area -> physical screen pixels.
    pub fn to_screen(self, p: V2) -> (f32, f32) {
        (self.work.0 as f32 + p.x * self.scale, self.work.1 as f32 + p.y * self.scale)
    }
}

#[derive(Debug)]
pub enum DesktopError {
    Denied(String),
    NoItems,
}

#[derive(Clone)]
pub struct Target {
    pub index: usize,
    pub path: PathBuf,
    pub modified: Option<SystemTime>,
    /// Icon centre in screen pixels, for putting it back.
    pub position: (f32, f32),
}

#[derive(Clone)]
pub struct Trashed {
    pub original: PathBuf,
    pub recycled: PathBuf,
    pub info: PathBuf,
    pub position: (f32, f32),
}

#[derive(Default)]
pub struct Outcome {
    pub done: Vec<usize>,
    pub failed: Vec<(usize, String)>,
    pub trashed: Vec<Trashed>,
}

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(not(windows))]
mod other {
    use super::*;
    use crate::entries::DesktopEntry;
    use image::RgbaImage;

    pub fn com_init() {}
    pub fn primary_screen() -> Screen {
        Screen {
            work: (0, 0, 1920, 1032),
            monitor: (0, 0, 1920, 1080),
            scale: 1.0,
        }
    }
    pub fn read_desktop(_: &Screen) -> Result<Vec<DesktopEntry>, DesktopError> {
        Err(DesktopError::Denied("Reading the desktop only works on Windows".into()))
    }
    pub fn sandbox(_: &std::path::Path, _: f32) -> Vec<DesktopEntry> {
        Vec::new()
    }
    pub fn system_icon(_: &DesktopEntry, _: u32) -> Option<RgbaImage> {
        None
    }
    pub fn desktop_grid(_: &Screen) -> Option<(V2, V2)> {
        None
    }
    pub fn wallpaper(_: &Screen) -> Option<RgbaImage> {
        None
    }
    pub fn desktop_dir() -> PathBuf {
        PathBuf::from(std::env::var("HOME").unwrap_or_default()).join("Desktop")
    }
    pub struct Hidden;
    pub fn hide_windows(_: &[isize]) -> Hidden {
        Hidden
    }
    pub fn restore_windows(_: Hidden) {}
    pub fn set_topmost(_: isize, _: bool) {}

    pub mod fileops {
        use super::super::*;
        use std::path::Path;
        pub fn delete(t: &[Target], _: &Path) -> Outcome {
            Outcome {
                failed: t.iter().map(|t| (t.index, "Only on Windows".into())).collect(),
                ..Default::default()
            }
        }
        pub fn trash(t: &[Target], r: &Path) -> Outcome {
            delete(t, r)
        }
        pub fn undo_trash(_: &[Trashed]) -> usize {
            0
        }
        pub fn set_positions(_: &[(PathBuf, (f32, f32))]) -> Result<(), String> {
            Err("Only on Windows".into())
        }
        pub fn desktop_is_freeform() -> bool {
            false
        }
        pub fn append_log(_: &str) {}
    }
}
#[cfg(not(windows))]
pub use other::*;
