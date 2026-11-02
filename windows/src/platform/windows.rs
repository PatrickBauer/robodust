//! Explorer, the wallpaper, the Recycle Bin and other windows. Everything here that changes a file
//! lives in `fileops`; the rest only reads.

use super::{DesktopError, Screen};
use crate::entries::{DesktopEntry, Kind};
use crate::math::{V2, v2};
use image::RgbaImage;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Controls::IImageList;
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HRESULT, Interface, PCWSTR, PWSTR};

pub fn com_init() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn take_pwstr(p: PWSTR) -> String {
    unsafe {
        let s = p.to_string().unwrap_or_default();
        CoTaskMemFree(Some(p.0 as *const _));
        s
    }
}

pub fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
    unsafe {
        SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None)
            .ok()
            .map(|p| PathBuf::from(take_pwstr(p)))
    }
}

pub fn desktop_dir() -> PathBuf {
    known_folder(&FOLDERID_Desktop).unwrap_or_else(|| PathBuf::from(std::env::var("USERPROFILE").unwrap_or_default()).join("Desktop"))
}

// MARK: - Screen

pub fn primary_screen() -> Screen {
    unsafe {
        let mon = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let _ = GetMonitorInfoW(mon, &mut mi);
        let mut dx = 96u32;
        let mut dy = 96u32;
        let _ = windows::Win32::UI::HiDpi::GetDpiForMonitor(mon, windows::Win32::UI::HiDpi::MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
        let w = mi.rcWork;
        let m = mi.rcMonitor;
        Screen {
            work: (w.left, w.top, (w.right - w.left) as u32, (w.bottom - w.top) as u32),
            monitor: (m.left, m.top, (m.right - m.left) as u32, (m.bottom - m.top) as u32),
            scale: dx as f32 / 96.0,
        }
    }
}

// MARK: - The desktop's own view

/// Explorer's view of the desktop: the same object Explorer uses to draw and place its icons.
fn desktop_view() -> windows::core::Result<IFolderView2> {
    unsafe {
        let windows: IShellWindows = CoCreateInstance(&ShellWindows, None, CLSCTX_ALL)?;
        let loc = VARIANT::from(0i32); // CSIDL_DESKTOP
        let empty = VARIANT::default();
        let mut hwnd = 0i32;
        let disp = windows.FindWindowSW(&loc, &empty, SWC_DESKTOP, &mut hwnd, SWFO_NEEDDISPATCH)?;
        let sp: windows::Win32::System::Com::IServiceProvider = disp.cast()?;
        let browser: IShellBrowser = sp.QueryService(&SID_STopLevelBrowser)?;
        let view = browser.QueryActiveShellView()?;
        view.cast()
    }
}

struct ViewItem {
    pidl: *mut ITEMIDLIST,
    item: IShellItem,
}

impl Drop for ViewItem {
    fn drop(&mut self) {
        unsafe { CoTaskMemFree(Some(self.pidl as *const _)) }
    }
}

fn view_items(view: &IFolderView2) -> windows::core::Result<Vec<ViewItem>> {
    unsafe {
        let n = view.ItemCount(SVGIO_ALLVIEW)?;
        let mut out = Vec::with_capacity(n as usize);
        for i in 0..n {
            let Ok(pidl) = view.Item(i) else { continue };
            let Ok(item) = view.GetItem::<IShellItem>(i) else {
                CoTaskMemFree(Some(pidl as *const _));
                continue;
            };
            out.push(ViewItem { pidl, item });
        }
        Ok(out)
    }
}

fn virtual_origin() -> (i32, i32) {
    unsafe { (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN)) }
}

/// Explorer reports the top-left corner of an item's icon box (icon-sized wide, in the middle of the
/// grid cell); the image itself sits a few pixels below that box's top. Measured on Windows 11.
fn icon_center_offset(view: &IFolderView2) -> (f32, f32) {
    unsafe {
        let mut spacing = POINT::default();
        let _ = view.GetSpacing(&mut spacing);
        let mut mode = FOLDERVIEWMODE::default();
        let mut icon = 48;
        let _ = view.GetViewModeAndIconSize(&mut mode, &mut icon);
        let scale = primary_screen().scale;
        let icon_px = icon as f32 * scale;
        crate::debug_log(&format!(
            "desktop: spacing {},{}, mode {}, icon {icon}",
            spacing.x, spacing.y, mode.0
        ));
        (icon_px / 2.0, icon_px / 2.0 + 5.0 * scale)
    }
}

/// Explorer's icon grid in work-area logical pixels: centre of the first cell, and the pitch.
pub fn desktop_grid(screen: &Screen) -> Option<(V2, V2)> {
    com_init();
    let view = desktop_view().ok()?;
    let mut spacing = POINT::default();
    unsafe { view.GetSpacing(&mut spacing).ok()? };
    if spacing.x <= 0 || spacing.y <= 0 {
        return None;
    }
    let (_, oy) = icon_center_offset(&view);
    let s = screen.scale;
    // The first row's icon box starts 2 px below the top; its column is centred in the cell.
    Some((
        v2(spacing.x as f32 / 2.0 / s, (2.0 * s + oy) / s),
        v2(spacing.x as f32 / s, spacing.y as f32 / s),
    ))
}

/// Read-only: asks Explorer for names and icon positions.
pub fn read_desktop(screen: &Screen) -> Result<Vec<DesktopEntry>, DesktopError> {
    com_init();
    let view = desktop_view().map_err(|e| DesktopError::Denied(e.message()))?;
    let items = view_items(&view).map_err(|e| DesktopError::Denied(e.message()))?;
    if items.is_empty() {
        return Err(DesktopError::NoItems);
    }
    let (vx, vy) = virtual_origin();
    let (ox, oy) = icon_center_offset(&view);
    crate::debug_log(&format!(
        "desktop: virtual origin {vx},{vy}, centre offset {ox},{oy}, work {:?}, scale {}",
        screen.work, screen.scale
    ));
    let public = known_folder(&FOLDERID_PublicDesktop);
    let mine = desktop_dir();
    let cloud_root = std::env::var("OneDrive").ok().map(PathBuf::from);
    let mut out = Vec::new();
    for vi in &items {
        let Ok(pt) = (unsafe { view.GetItemPosition(vi.pidl) }) else {
            continue;
        };
        // Screen pixels of the icon centre, then logical pixels inside the work area.
        let sx = (pt.x + vx) as f32 + ox;
        let sy = (pt.y + vy) as f32 + oy;
        let cx = (sx - screen.work.0 as f32) / screen.scale;
        let cy = (sy - screen.work.1 as f32) / screen.scale;
        if cx < 0.0 || cy < 0.0 || cx > screen.work.2 as f32 / screen.scale || cy > screen.work.3 as f32 / screen.scale {
            continue;
        }
        let shown = unsafe { vi.item.GetDisplayName(SIGDN_NORMALDISPLAY) }
            .map(take_pwstr)
            .unwrap_or_default();
        crate::debug_log(&format!("desktop: {shown:?} at {},{}", pt.x, pt.y));
        let path = unsafe { vi.item.GetDisplayName(SIGDN_FILESYSPATH) }
            .ok()
            .map(take_pwstr)
            .map(PathBuf::from);
        let mut e = match &path {
            Some(p) => entry(p, &shown),
            None => {
                // This PC, the Recycle Bin and friends: drawn and nudged, never collected.
                let mut e = DesktopEntry::sample(&shown, v2(0.0, 0.0), 0, Kind::Other, None);
                e.shell_id = unsafe { vi.item.GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING) }.ok().map(take_pwstr);
                e.missing = true;
                e.protected_reason = Some("Not a file on the desktop".into());
                e
            }
        };
        e.center = v2(cx, cy);
        if let Some(p) = &path {
            let parent = p.parent().map(Path::to_path_buf);
            if parent.as_ref() != Some(&mine) {
                if public.is_some() && parent == public {
                    e.protected_reason = Some("Shared with every user of this PC".into());
                } else {
                    e.protected_reason = Some("Not in your Desktop folder".into());
                }
                e.missing = true;
            }
            e.cloud = cloud_root.as_ref().is_some_and(|r| p.starts_with(r));
        }
        out.push(e);
    }
    if out.is_empty() {
        return Err(DesktopError::NoItems);
    }
    Ok(out)
}

fn dir_size(p: &Path, budget: &mut u32) -> i64 {
    let mut total = 0;
    let Ok(rd) = std::fs::read_dir(p) else { return 0 };
    for e in rd.flatten() {
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        let Ok(md) = e.metadata() else { continue };
        if md.is_dir() {
            total += dir_size(&e.path(), budget);
        } else {
            total += md.len() as i64;
        }
    }
    total
}

pub fn entry(path: &Path, shown: &str) -> DesktopEntry {
    use std::os::windows::fs::MetadataExt;
    let md = std::fs::symlink_metadata(path).ok();
    let is_dir = md.as_ref().is_some_and(|m| m.is_dir());
    let file_name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let bytes = match &md {
        Some(m) if is_dir => {
            let mut budget = 4000;
            let s = dir_size(path, &mut budget);
            if budget == 0 { s.max(40_000_000) } else { s }
        }
        Some(m) => m.len() as i64,
        None => 200_000,
    };
    let mut e = DesktopEntry::sample(shown, v2(0.0, 0.0), bytes, Kind::of_name(&file_name, is_dir), None);
    e.path = Some(path.to_path_buf());
    e.modified = md.as_ref().and_then(|m| m.modified().ok());
    let ext = path
        .extension()
        .map(|x| x.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let attrs = md.as_ref().map(|m| m.file_attributes()).unwrap_or(0);
    if md.is_none() {
        e.missing = true;
        e.protected_reason = Some("Not a file on the desktop".into());
    } else if !is_dir && attrs & FILE_ATTRIBUTE_READONLY.0 != 0 {
        e.protected_reason = Some("Read-only".into());
    } else if attrs & FILE_ATTRIBUTE_SYSTEM.0 != 0 {
        e.protected_reason = Some("System file".into());
    } else if e
        .modified
        .is_some_and(|m| SystemTime::now().duration_since(m).map(|d| d.as_secs() < 600).unwrap_or(true))
    {
        e.protected_reason = Some("Changed in the last 10 minutes".into());
    } else if is_dir && path.join(".git").exists() {
        e.protected_reason = Some("Code project".into());
    } else if matches!(ext.as_str(), "exe" | "lnk" | "url" | "appref-ms" | "msc") {
        e.protected_reason = Some("App or shortcut".into());
    }
    e
}

/// Dev only: treats a throwaway folder as if it were the desktop.
pub fn sandbox(root: &Path, w: f32) -> Vec<DesktopEntry> {
    let mut names: Vec<_> = std::fs::read_dir(root)
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    names.retain(|n: &String| !n.starts_with('.'));
    names.sort();
    names
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let mut e = entry(&root.join(n), n);
            e.center = v2(w * 0.3 + (i % 8) as f32 * 100.0, 160.0 + (i / 8) as f32 * 110.0);
            e
        })
        .collect()
}

// MARK: - Icons

fn bitmap_to_rgba(hbm: HBITMAP) -> Option<RgbaImage> {
    unsafe {
        let mut bm = BITMAP::default();
        if GetObjectW(hbm.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as *mut _)) == 0 {
            return None;
        }
        let (w, h) = (bm.bmWidth, bm.bmHeight.abs());
        let mut bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut buf = vec![0u8; (w * h * 4) as usize];
        let dc = GetDC(None);
        let lines = GetDIBits(dc, hbm, 0, h as u32, Some(buf.as_mut_ptr() as *mut _), &mut bi, DIB_RGB_COLORS);
        ReleaseDC(None, dc);
        if lines == 0 {
            return None;
        }
        let any_alpha = buf.chunks(4).any(|p| p[3] != 0);
        let mut img = RgbaImage::new(w as u32, h as u32);
        for (i, p) in img.pixels_mut().enumerate() {
            let s = &buf[i * 4..i * 4 + 4];
            let a = if any_alpha { s[3] } else { 255 };
            // GDI hands back premultiplied BGRA; the sprite code wants straight RGBA.
            let un = |c: u8| {
                if a == 0 {
                    0
                } else {
                    ((c as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8
                }
            };
            *p = if any_alpha {
                image::Rgba([un(s[2]), un(s[1]), un(s[0]), a])
            } else {
                image::Rgba([s[2], s[1], s[0], 255])
            };
        }
        Some(img)
    }
}

fn icon_to_rgba(icon: HICON) -> Option<RgbaImage> {
    unsafe {
        let mut ii = ICONINFO::default();
        GetIconInfo(icon, &mut ii).ok()?;
        let img = bitmap_to_rgba(ii.hbmColor);
        let _ = DeleteObject(ii.hbmColor.into());
        let _ = DeleteObject(ii.hbmMask.into());
        let _ = DestroyIcon(icon);
        img
    }
}

/// What Explorer would draw for this entry: a thumbnail for pictures, the file's icon otherwise.
pub fn system_icon(e: &DesktopEntry, px: u32) -> Option<RgbaImage> {
    com_init();
    unsafe {
        if let Some(name) = e
            .path
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned())
            .or_else(|| e.shell_id.clone())
        {
            let w = wide(&name);
            let f: IShellItemImageFactory = SHCreateItemFromParsingName(PCWSTR(w.as_ptr()), None).ok()?;
            let hbm = f
                .GetImage(
                    SIZE {
                        cx: px as i32,
                        cy: px as i32,
                    },
                    SIIGBF_RESIZETOFIT,
                )
                .ok()?;
            let img = bitmap_to_rgba(hbm);
            let _ = DeleteObject(hbm.into());
            return img;
        }
        // Sample items have no file: ask for the icon of their type instead.
        let (name, attrs) = if e.kind == Kind::Folder {
            ("folder".to_string(), FILE_ATTRIBUTE_DIRECTORY)
        } else {
            (e.name.clone(), FILE_ATTRIBUTE_NORMAL)
        };
        let w = wide(&name);
        let mut sfi = SHFILEINFOW::default();
        SHGetFileInfoW(
            PCWSTR(w.as_ptr()),
            attrs,
            Some(&mut sfi),
            std::mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_SYSICONINDEX | SHGFI_USEFILEATTRIBUTES,
        );
        let list: IImageList = SHGetImageList(SHIL_JUMBO as i32).ok()?;
        let icon = list.GetIcon(sfi.iIcon, 0x1 /* ILD_TRANSPARENT */).ok()?;
        let img = icon_to_rgba(icon)?;
        // Types without a big icon come back as 48 px in the corner of a 256 px canvas.
        Some(trim_small_icon(img))
    }
}

fn trim_small_icon(img: RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let (mut maxx, mut maxy) = (0, 0);
    for (x, y, p) in img.enumerate_pixels() {
        if p[3] > 0 {
            maxx = maxx.max(x);
            maxy = maxy.max(y);
        }
    }
    if w >= 256 && maxx < 48 && maxy < 48 {
        return image::imageops::crop_imm(&img, 0, 0, 48, 48).to_image();
    }
    let _ = h;
    img
}

// MARK: - Wallpaper

fn load_image(path: &Path) -> Option<RgbaImage> {
    let bytes = std::fs::read(path).ok()?;
    image::load_from_memory(&bytes).ok().map(|i| i.to_rgba8())
}

/// The monitor's wallpaper, composed like Explorer does, cropped to the work area.
pub fn wallpaper(screen: &Screen) -> Option<RgbaImage> {
    com_init();
    let (mx, my, mw, mh) = screen.monitor;
    let (mut path, mut pos, mut bg) = (None, DWPOS_FILL, [0u8, 0, 0]);
    unsafe {
        if let Ok(dw) = CoCreateInstance::<_, IDesktopWallpaper>(&DesktopWallpaper, None, CLSCTX_ALL) {
            pos = dw.GetPosition().unwrap_or(DWPOS_FILL);
            if let Ok(c) = dw.GetBackgroundColor() {
                bg = [(c.0 & 0xff) as u8, ((c.0 >> 8) & 0xff) as u8, ((c.0 >> 16) & 0xff) as u8];
            }
            let n = dw.GetMonitorDevicePathCount().unwrap_or(0);
            for i in 0..n {
                let Ok(id) = dw.GetMonitorDevicePathAt(i) else { continue };
                let r = dw.GetMonitorRECT(PCWSTR(id.0));
                if r.is_ok_and(|r| r.left == mx && r.top == my)
                    && let Ok(p) = dw.GetWallpaper(PCWSTR(id.0))
                {
                    let s = take_pwstr(p);
                    if !s.is_empty() {
                        path = Some(PathBuf::from(s));
                    }
                }
                CoTaskMemFree(Some(id.0 as *const _));
            }
        }
    }
    let src = path.as_deref().and_then(load_image).or_else(|| {
        // Spotlight and slideshows keep the current picture here.
        let p = PathBuf::from(std::env::var("APPDATA").ok()?).join("Microsoft\\Windows\\Themes\\TranscodedWallpaper");
        load_image(&p)
    });
    let mut canvas = RgbaImage::from_pixel(mw, mh, image::Rgba([bg[0], bg[1], bg[2], 255]));
    if let Some(src) = src {
        let (sw, sh) = (src.width() as f32, src.height() as f32);
        let place = |img: &RgbaImage, canvas: &mut RgbaImage, x: i64, y: i64| image::imageops::overlay(canvas, img, x, y);
        use image::imageops::{FilterType, resize};
        match pos {
            DWPOS_CENTER => place(&src, &mut canvas, (mw as i64 - sw as i64) / 2, (mh as i64 - sh as i64) / 2),
            DWPOS_TILE => {
                for y in (0..mh).step_by(sh as usize) {
                    for x in (0..mw).step_by(sw as usize) {
                        place(&src, &mut canvas, x as i64, y as i64);
                    }
                }
            }
            DWPOS_STRETCH => canvas = resize(&src, mw, mh, FilterType::Triangle),
            DWPOS_FIT => {
                let k = (mw as f32 / sw).min(mh as f32 / sh);
                let (w, h) = ((sw * k) as u32, (sh * k) as u32);
                let r = resize(&src, w, h, FilterType::Triangle);
                place(&r, &mut canvas, (mw as i64 - w as i64) / 2, (mh as i64 - h as i64) / 2);
            }
            _ => {
                // Fill (and span, approximated on one monitor).
                let k = (mw as f32 / sw).max(mh as f32 / sh);
                let (w, h) = ((sw * k).ceil() as u32, (sh * k).ceil() as u32);
                let r = resize(&src, w, h, FilterType::Triangle);
                place(&r, &mut canvas, -((w as i64 - mw as i64) / 2), -((h as i64 - mh as i64) / 2));
            }
        }
    } else if path.is_none() && bg == [0, 0, 0] {
        return None;
    }
    let (wx, wy, ww, wh) = screen.work;
    Some(image::imageops::crop_imm(&canvas, (wx - mx) as u32, (wy - my) as u32, ww, wh).to_image())
}

// MARK: - Other windows

pub struct Hidden(Vec<isize>);

unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> windows::core::BOOL {
    unsafe {
        let out = &mut *(lparam.0 as *mut Vec<isize>);
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() {
            return true.into();
        }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 || style & WS_MINIMIZEBOX.0 == 0 {
            return true.into();
        }
        if GetWindow(hwnd, GW_OWNER).is_ok_and(|o| !o.is_invalid()) {
            return true.into();
        }
        let mut class = [0u16; 64];
        let n = GetClassNameW(hwnd, &mut class);
        let class = String::from_utf16_lossy(&class[..n as usize]);
        if matches!(class.as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") {
            return true.into();
        }
        out.push(hwnd.0 as isize);
        true.into()
    }
}

/// Minimises every ordinary app window except ours, so the floor is clear to watch.
pub fn hide_windows(keep: &[isize]) -> Hidden {
    let mut found: Vec<isize> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut found as *mut _ as isize));
    }
    found.retain(|h| !keep.contains(h));
    for &h in &found {
        unsafe {
            let _ = ShowWindowAsync(HWND(h as *mut _), SW_SHOWMINNOACTIVE);
        }
    }
    Hidden(found)
}

pub fn restore_windows(h: Hidden) {
    for &w in h.0.iter().rev() {
        unsafe {
            let _ = ShowWindowAsync(HWND(w as *mut _), SW_RESTORE);
        }
    }
}

/// The panel stays above everything; the floor stays wherever the user leaves it.
pub fn set_topmost(hwnd: isize, on: bool) {
    unsafe {
        let _ = SetWindowPos(
            HWND(hwnd as *mut _),
            Some(if on { HWND_TOPMOST } else { HWND_NOTOPMOST }),
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
    }
}

// MARK: - File operations

pub mod fileops {
    use super::*;
    use crate::platform::{Outcome, Target, Trashed};

    /// None means safe to act on. Never follows links: acts on the link itself.
    pub fn refusal(t: &Target, root: &Path) -> Option<String> {
        let name = t.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if name.is_empty() || name == "." || name == ".." {
            return Some("Unsafe name".into());
        }
        let parent = t.path.parent().and_then(|p| std::fs::canonicalize(p).ok());
        if parent.is_none() || parent != std::fs::canonicalize(root).ok() {
            return Some("Not directly on the desktop".into());
        }
        let Ok(md) = std::fs::symlink_metadata(&t.path) else {
            return Some("No longer there".into());
        };
        if let (Some(then), Ok(now)) = (t.modified, md.modified()) {
            let d = now.duration_since(then).unwrap_or_else(|e| e.duration());
            if d.as_secs_f64() > 1.0 {
                return Some("Changed during the clean".into());
            }
        }
        None
    }

    pub fn delete(targets: &[Target], root: &Path) -> Outcome {
        let mut out = Outcome::default();
        for t in targets {
            if let Some(why) = refusal(t, root) {
                out.failed.push((t.index, why));
                continue;
            }
            let is_dir = std::fs::symlink_metadata(&t.path).map(|m| m.is_dir()).unwrap_or(false);
            let r = if is_dir {
                std::fs::remove_dir_all(&t.path)
            } else {
                std::fs::remove_file(&t.path)
            };
            match r {
                Ok(()) => out.done.push(t.index),
                Err(e) => out.failed.push((t.index, e.to_string())),
            }
        }
        log("delete", &out, targets);
        out
    }

    /// Through the shell, so everything can be restored from the Recycle Bin as usual.
    pub fn trash(targets: &[Target], root: &Path) -> Outcome {
        com_init();
        let mut out = Outcome::default();
        let mut allowed = Vec::new();
        for t in targets {
            match refusal(t, root) {
                Some(why) => out.failed.push((t.index, why)),
                None => allowed.push(t),
            }
        }
        let started = SystemTime::now();
        // One operation per item, so every error and refusal belongs to the item it was about.
        let mut errors: Vec<(PathBuf, String)> = Vec::new();
        for t in &allowed {
            // Again right before the move: an earlier item may have waited on a dialog or a slow disk.
            if let Some(why) = refusal(t, root) {
                errors.push((t.path.clone(), why));
                continue;
            }
            let result: Result<bool, String> = unsafe {
                CoCreateInstance::<_, IFileOperation>(&FileOperation, None, CLSCTX_ALL)
                    .map_err(|e| e.message())
                    .and_then(|op| {
                        // FOF_NO_UI alone would silently delete for good whatever can't be recycled (too big for the
                        // Recycle Bin, a drive without one). FOF_WANTNUKEWARNING makes Windows ask first instead.
                        // FOF_NO_CONNECTED_ELEMENTS: only the item asked for, not a saved page's _files folder.
                        op.SetOperationFlags(
                            FOF_ALLOWUNDO | FOFX_RECYCLEONDELETE | FOF_NO_UI | FOF_WANTNUKEWARNING | FOF_NO_CONNECTED_ELEMENTS,
                        )
                        .map_err(|e| e.message())?;
                        let w = wide(&t.path.to_string_lossy());
                        let item: IShellItem = SHCreateItemFromParsingName(PCWSTR(w.as_ptr()), None).map_err(|e| e.message())?;
                        op.DeleteItem(&item, None).map_err(|e| e.message())?;
                        let done = op.PerformOperations();
                        let aborted = op.GetAnyOperationsAborted().map(|b| b.as_bool()).unwrap_or(false);
                        match done {
                            Ok(()) => Ok(aborted),
                            Err(e) if e.code() == COPYENGINE_E_USER_CANCELLED || e.code() == HRESULT::from_win32(ERROR_CANCELLED.0) => {
                                Ok(true)
                            }
                            Err(e) => Err(e.message()),
                        }
                    })
            };
            match result {
                Ok(true) => errors.push((t.path.clone(), "It can't go to the Recycle Bin, so it was left alone".into())),
                Ok(false) => {}
                Err(e) if e.is_empty() => errors.push((t.path.clone(), "Windows couldn't move it".into())),
                Err(e) => errors.push((t.path.clone(), e)),
            }
        }
        // The filesystem decides what happened, not the shell's answer.
        let records = recycle_records(root, started);
        for t in allowed {
            if std::fs::symlink_metadata(&t.path).is_err() {
                out.done.push(t.index);
                if let Some((r, i)) = records
                    .iter()
                    .filter(|r| r.original == t.path)
                    .max_by_key(|r| r.deleted)
                    .map(|r| (r.recycled.clone(), r.info.clone()))
                {
                    out.trashed.push(Trashed {
                        original: t.path.clone(),
                        recycled: r,
                        info: i,
                        position: t.position,
                    });
                }
            } else {
                let why = errors.iter().find(|(p, _)| *p == t.path).map(|(_, e)| e.clone());
                out.failed.push((t.index, why.unwrap_or_else(|| "Windows couldn't move it".into())));
            }
        }
        log("recycle", &out, targets);
        out
    }

    struct Record {
        original: PathBuf,
        recycled: PathBuf,
        info: PathBuf,
        deleted: u64,
    }

    /// Reads the Recycle Bin's own index files ($I…) on the cleaned folder's drive, newest first.
    fn recycle_records(root: &Path, since: SystemTime) -> Vec<Record> {
        let drive: PathBuf = root.components().take(2).collect();
        let since_ft = since
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs() + 11_644_473_600)
            .unwrap_or(0)
            .saturating_sub(5)
            * 10_000_000;
        let mut out = Vec::new();
        let Ok(bins) = std::fs::read_dir(drive.join("$Recycle.Bin")) else {
            return out;
        };
        for bin in bins.flatten() {
            let Ok(files) = std::fs::read_dir(bin.path()) else { continue };
            for f in files.flatten() {
                let name = f.file_name().to_string_lossy().to_string();
                let Some(rest) = name.strip_prefix("$I") else { continue };
                let Ok(b) = std::fs::read(f.path()) else { continue };
                if b.len() < 28 {
                    continue;
                }
                let version = u64::from_le_bytes(b[0..8].try_into().unwrap());
                let deleted = u64::from_le_bytes(b[16..24].try_into().unwrap());
                if deleted < since_ft {
                    continue;
                }
                let utf16: Vec<u16> = if version >= 2 {
                    let n = u32::from_le_bytes(b[24..28].try_into().unwrap()) as usize;
                    b[28..].as_chunks::<2>().0.iter().take(n).map(|c| u16::from_le_bytes(*c)).collect()
                } else {
                    b[24..].as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect()
                };
                let s = String::from_utf16_lossy(&utf16).trim_end_matches('\0').to_string();
                out.push(Record {
                    original: PathBuf::from(s),
                    recycled: bin.path().join(format!("$R{rest}")),
                    info: f.path(),
                    deleted,
                });
            }
        }
        out
    }

    /// Moves items back out of the Recycle Bin, under their original names, like Restore does.
    pub fn undo_trash(items: &[Trashed]) -> usize {
        let mut restored = Vec::new();
        for t in items {
            if t.original.exists() || !t.recycled.exists() {
                continue;
            }
            if std::fs::rename(&t.recycled, &t.original).is_ok() {
                // The index entry would otherwise stay behind as a broken item in the Recycle Bin.
                let _ = std::fs::remove_file(&t.info);
                restored.push((t.original.clone(), t.position));
            }
        }
        // Give Explorer a moment to notice them before placing them where they were.
        std::thread::sleep(std::time::Duration::from_millis(800));
        let _ = set_positions(&restored);
        append_log(&format!("undo recycle: restored {} of {}", restored.len(), items.len()));
        restored.len()
    }

    /// Tidy up changes where icons sit, never where files live. Positions are icon centres in screen pixels.
    pub fn set_positions(moves: &[(PathBuf, (f32, f32))]) -> Result<(), String> {
        com_init();
        let view = desktop_view().map_err(|e| e.message())?;
        let items = view_items(&view).map_err(|e| e.message())?;
        let (vx, vy) = virtual_origin();
        let (ox, oy) = icon_center_offset(&view);
        let mut failed = 0;
        for (path, (x, y)) in moves {
            let found = items.iter().find(|vi| {
                unsafe { vi.item.GetDisplayName(SIGDN_FILESYSPATH) }
                    .ok()
                    .map(take_pwstr)
                    .is_some_and(|p| Path::new(&p) == path)
            });
            let Some(vi) = found else {
                failed += 1;
                continue;
            };
            let pt = POINT {
                x: (x - ox).round() as i32 - vx,
                y: (y - oy).round() as i32 - vy,
            };
            let pidl = vi.pidl as *const ITEMIDLIST;
            if unsafe { view.SelectAndPositionItems(1, &pidl, Some(&pt), SVSI_POSITIONITEM.0 as u32) }.is_err() {
                failed += 1;
            }
        }
        if failed > 0 {
            Err(format!("{failed} icons didn't move"))
        } else {
            Ok(())
        }
    }

    /// Tidy can't work while Explorer keeps the desktop auto-arranged.
    pub fn desktop_is_freeform() -> bool {
        com_init();
        let Ok(view) = desktop_view() else { return false };
        unsafe {
            view.GetCurrentFolderFlags()
                .map(|f| f & FWF_AUTOARRANGE.0 as u32 == 0)
                .unwrap_or(false)
        }
    }

    fn history_path() -> PathBuf {
        let dir = PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into())).join("RoboDust");
        let _ = std::fs::create_dir_all(&dir);
        dir.join("history.log")
    }

    fn log(action: &str, o: &Outcome, targets: &[Target]) {
        let by_index = |i: usize| targets.iter().find(|t| t.index == i).map(|t| t.path.display().to_string());
        let mut lines = vec![format!("{action}: {} done, {} left alone", o.done.len(), o.failed.len())];
        lines.extend(o.done.iter().filter_map(|&i| by_index(i).map(|p| format!("  done {p}"))));
        lines.extend(
            o.failed
                .iter()
                .filter_map(|(i, why)| by_index(*i).map(|p| format!("  left {p} ({why})"))),
        );
        append_log(&lines.join("\n"));
    }

    pub fn append_log(text: &str) {
        use std::io::Write;
        let stamp = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(history_path()) {
            let _ = writeln!(f, "[{stamp}] {text}");
        }
    }
}
