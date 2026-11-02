//! The control panel, drawn with egui. Mirrors Panel.swift: setup, preparing, running, decision.

use crate::entries::Kind;
use crate::math::V2;
use crate::sim::{CleanMode, Phase, Sim};
use egui::{Color32, CornerRadius, RichText, Stroke, Vec2};
use std::collections::HashSet;

pub const ACCENT: Color32 = Color32::from_rgb(92, 214, 250);
const BG: Color32 = Color32::from_rgb(23, 23, 23);
const SECONDARY: Color32 = Color32::from_rgb(160, 160, 165);
const ORANGE: Color32 = Color32::from_rgb(255, 159, 10);
pub const PANEL_WIDTH: f32 = 372.0;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Ready,
    Preparing,
    Running,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Sample,
    Real,
}

#[derive(Clone)]
pub struct RunResult {
    pub title: String,
    pub detail: Option<String>,
    pub can_undo: bool,
    pub is_error: bool,
}

impl RunResult {
    pub fn plain(t: impl Into<String>) -> Self {
        RunResult {
            title: t.into(),
            detail: None,
            can_undo: false,
            is_error: false,
        }
    }
}

/// Everything the panel shows. Actions come back as `Action`s for the app to carry out.
pub struct Model {
    pub stage: Stage,
    pub source: Source,
    pub mode: CleanMode,
    pub skip_final_click: bool,
    pub clear_windows: bool,
    pub muted: bool,
    pub outcome: Option<CleanMode>,
    pub real_run: bool,
    pub applying: bool,
    pub delete_countdown: Option<i32>,
    pub result: Option<RunResult>,
    pub excluded: HashSet<usize>,
    pub review_open: bool,
    pub review_rows: Vec<(usize, String)>,
    pub file_bytes: i64,
    pub folder_count: usize,
    pub left_alone: usize,
    pub uses_cloud: bool,
    pub prepared: usize,
    pub prepare_total: usize,
    pub note: Option<String>,
    pub total: usize,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    Start,
    TogglePause,
    Stop,
    PutBack,
    Choose(CleanMode),
    CancelCountdown,
    Undo,
    DismissResult,
    SettingsChanged,
}

impl Model {
    pub fn new() -> Model {
        let (mode, skip) = load_settings();
        Model {
            stage: Stage::Ready,
            source: Source::Sample,
            mode,
            skip_final_click: skip,
            clear_windows: true,
            muted: false,
            outcome: None,
            real_run: false,
            applying: false,
            delete_countdown: None,
            result: None,
            excluded: HashSet::new(),
            review_open: false,
            review_rows: Vec::new(),
            file_bytes: 0,
            folder_count: 0,
            left_alone: 0,
            uses_cloud: false,
            prepared: 0,
            prepare_total: 0,
            note: None,
            total: 0,
        }
    }
    pub fn save(&self) {
        save_settings(self.mode, self.skip_final_click);
    }
}

fn settings_path() -> std::path::PathBuf {
    let base = std::env::var("LOCALAPPDATA")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(base).join("RoboDust").join("settings.txt")
}
fn load_settings() -> (CleanMode, bool) {
    let s = std::fs::read_to_string(settings_path()).unwrap_or_default();
    let mut mode = CleanMode::Trash;
    let mut skip = false;
    for line in s.lines() {
        if let Some(v) = line.strip_prefix("afterClean=") {
            mode = v
                .parse()
                .ok()
                .and_then(CleanMode::from_index)
                .filter(|m| m.offered())
                .unwrap_or(mode);
        }
        if let Some(v) = line.strip_prefix("skipFinalClick=") {
            skip = v == "1";
        }
    }
    (mode, skip)
}
fn save_settings(mode: CleanMode, skip: bool) {
    let p = settings_path();
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let _ = std::fs::write(p, format!("afterClean={}\nskipFinalClick={}\n", mode.index(), skip as u8));
}

pub fn fmt_bytes(b: i64) -> String {
    let b = b as f64;
    if b < 1e3 {
        format!("{b} bytes")
    } else if b < 1e6 {
        format!("{:.0} KB", b / 1e3)
    } else if b < 1e9 {
        format!("{:.1} MB", b / 1e6)
    } else {
        format!("{:.2} GB", b / 1e9)
    }
}

pub fn setup_style(ctx: &egui::Context) {
    // Segoe UI first where it exists (the system look), Segoe UI Symbol for ⏸ ✕ 🔊 and the like;
    // egui's bundled fonts stay as fallback.
    let mut fonts = egui::FontDefinitions::default();
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
    let dir = std::path::Path::new(&windir).join("Fonts");
    for (i, (name, file)) in [("segoe", "segoeui.ttf"), ("segoe-symbol", "seguisym.ttf")].into_iter().enumerate() {
        if let Ok(bytes) = std::fs::read(dir.join(file)) {
            fonts
                .font_data
                .insert(name.into(), std::sync::Arc::new(egui::FontData::from_owned(bytes)));
            let family = fonts.families.entry(egui::FontFamily::Proportional).or_default();
            family.insert(i.min(family.len()), name.into());
        }
    }
    ctx.set_fonts(fonts);
    ctx.set_visuals(egui::Visuals::dark());
    ctx.global_style_mut(|s| {
        s.visuals.panel_fill = BG;
        s.visuals.window_fill = BG;
        s.visuals.override_text_color = Some(Color32::from_rgb(235, 235, 240));
        s.visuals.selection.bg_fill = ACCENT;
        s.visuals.selection.stroke = Stroke::new(1.0, Color32::BLACK);
        s.spacing.item_spacing = Vec2::new(8.0, 8.0);
        s.spacing.button_padding = Vec2::new(10.0, 6.0);
    });
}

#[derive(Clone, Copy)]
enum ButtonKind {
    Primary,
    Danger,
    Quiet,
}

fn big_button(ui: &mut egui::Ui, label: &str, kind: ButtonKind, enabled: bool) -> bool {
    let (fg, bg, border) = match kind {
        ButtonKind::Primary => (Color32::BLACK, ACCENT, Color32::TRANSPARENT),
        ButtonKind::Danger => (
            Color32::from_rgb(255, 140, 133),
            Color32::from_rgba_unmultiplied(255, 69, 59, 36),
            Color32::from_rgba_unmultiplied(255, 102, 92, 128),
        ),
        ButtonKind::Quiet => (Color32::WHITE, Color32::from_white_alpha(26), Color32::TRANSPARENT),
    };
    let b = egui::Button::new(RichText::new(label).size(14.0).strong().color(fg))
        .fill(bg)
        .stroke(Stroke::new(1.0, border))
        .corner_radius(CornerRadius::same(9))
        .min_size(Vec2::new(ui.available_width(), 36.0));
    ui.add_enabled(enabled, b).clicked()
}

fn half_buttons(ui: &mut egui::Ui, a: (&str, ButtonKind), b: (&str, ButtonKind)) -> (bool, bool) {
    let w = (ui.available_width() - 8.0) / 2.0;
    let mut out = (false, false);
    ui.horizontal(|ui| {
        ui.allocate_ui(Vec2::new(w, 36.0), |ui| out.0 = big_button(ui, a.0, a.1, true));
        ui.allocate_ui(Vec2::new(w, 36.0), |ui| out.1 = big_button(ui, b.0, b.1, true));
    });
    out
}

fn small(text: impl Into<String>) -> RichText {
    RichText::new(text).size(12.0).color(SECONDARY)
}

fn segmented<T: PartialEq + Copy>(ui: &mut egui::Ui, value: &mut T, options: &[(T, &str)]) -> bool {
    let mut changed = false;
    let w = (ui.available_width() - 4.0 * (options.len() as f32 - 1.0)) / options.len() as f32;
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        for &(v, label) in options {
            let on = *value == v;
            let b = egui::Button::new(
                RichText::new(label)
                    .size(13.0)
                    .color(if on { Color32::BLACK } else { Color32::WHITE }),
            )
            .fill(if on { ACCENT } else { Color32::from_white_alpha(20) })
            .corner_radius(CornerRadius::same(7))
            .min_size(Vec2::new(w, 28.0));
            if ui.add(b).clicked() && !on {
                *value = v;
                changed = true;
            }
        }
    });
    changed
}

/// Draws the panel. `sim` is the live run, if any.
pub fn panel(ui: &mut egui::Ui, m: &mut Model, sim: Option<&Sim>, actions: &mut Vec<Action>) {
    egui::Frame::new()
        .fill(BG)
        .inner_margin(egui::Margin {
            left: 20,
            right: 20,
            top: 18,
            bottom: 20,
        })
        .show(ui, |ui| {
            ui.set_width(PANEL_WIDTH - 40.0);
            header(ui, m, sim);
            ui.add_space(10.0);
            match m.stage {
                Stage::Ready => setup(ui, m, actions),
                Stage::Preparing => {
                    ui.label(RichText::new("Copying your icons…").size(13.0));
                    ui.add(
                        egui::ProgressBar::new(m.prepared as f32 / m.prepare_total.max(1) as f32)
                            .fill(ACCENT)
                            .desired_height(6.0),
                    );
                    ui.label(small(format!("{} of {}", m.prepared, m.prepare_total)));
                }
                Stage::Running => running(ui, m, sim, actions),
            }
        });
}

fn header(ui: &mut egui::Ui, m: &mut Model, sim: Option<&Sim>) {
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(Vec2::splat(30.0), egui::Sense::hover());
        let p = ui.painter();
        p.circle_filled(rect.center(), 15.0, Color32::from_gray(230));
        p.circle_filled(rect.center(), 10.5, Color32::from_gray(31));
        p.circle_filled(rect.center() + Vec2::new(0.0, -5.0), 4.8, ACCENT);
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 1.0;
            ui.label(RichText::new("RoboDust").size(17.0).strong());
            let status = if m.stage == Stage::Running {
                sim.map(|s| s.status.clone()).unwrap_or_default()
            } else {
                "Robot vacuum for your desktop".into()
            };
            ui.label(small(status));
        });
        if m.stage == Stage::Running {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let label = if m.muted { "🔇" } else { "🔊" };
                if ui
                    .add(egui::Button::new(RichText::new(label).size(14.0)).frame(false))
                    .on_hover_text("Sound")
                    .clicked()
                {
                    m.muted = !m.muted;
                }
            });
        }
    });
}

fn setup(ui: &mut egui::Ui, m: &mut Model, actions: &mut Vec<Action>) {
    if let Some(r) = m.result.clone() {
        result_card(ui, &r, actions);
        ui.add_space(4.0);
    }
    ui.label(small("Clean").strong());
    segmented(
        ui,
        &mut m.source,
        &[(Source::Sample, "Sample mess"), (Source::Real, "My real desktop")],
    );
    ui.add_space(6.0);
    ui.label(small("After cleaning").strong());
    let mut changed = segmented(ui, &mut m.mode, &[(CleanMode::Tidy, "Tidy up"), (CleanMode::Trash, "Recycle Bin")]);
    let ask = if m.skip_final_click {
        ""
    } else {
        " RoboDust asks for a final click first."
    };
    let blurb = match m.mode {
        CleanMode::Tidy => "Sorts everything into neat columns by type, automatically.".to_string(),
        CleanMode::Trash => format!("Moves everything to the Recycle Bin, where you can still get it back.{ask}"),
        CleanMode::Delete => format!("Permanently deletes everything.{ask}"),
    };
    ui.label(small(blurb));
    if m.mode != CleanMode::Tidy {
        changed |= ui
            .checkbox(&mut m.skip_final_click, RichText::new("Don't ask me, just clean up").size(13.0))
            .changed();
        if m.mode == CleanMode::Delete && m.skip_final_click {
            ui.label(
                RichText::new("With no final click, RoboDust will permanently delete everything it collects after a 10-second countdown.")
                    .size(12.0)
                    .color(ORANGE),
            );
        }
    }
    if changed {
        actions.push(Action::SettingsChanged);
    }
    ui.checkbox(&mut m.clear_windows, RichText::new("Minimise my windows so I can watch").size(13.0));
    if let Some(n) = &m.note {
        ui.label(RichText::new(n).size(12.0).color(ORANGE));
    }
    ui.add_space(4.0);
    if big_button(ui, "Start cleaning", ButtonKind::Primary, true) {
        actions.push(Action::Start);
    }
    let foot = if m.source != Source::Real {
        "The sample mess is made up, so nothing real is touched."
    } else {
        match m.mode {
            CleanMode::Tidy => "RoboDust will rearrange your real desktop icons. Your files don't move.",
            CleanMode::Trash => {
                "RoboDust will move your real files to the Recycle Bin. It leaves anything read-only, just changed, a shortcut or a code project alone."
            }
            CleanMode::Delete => {
                "RoboDust will permanently delete your real files. It leaves anything read-only, just changed, a shortcut or a code project alone."
            }
        }
    };
    ui.horizontal_top(|ui| {
        let (icon, col) = if m.source == Source::Real {
            ("⚠", ORANGE)
        } else {
            ("🛡", ACCENT)
        };
        ui.label(RichText::new(icon).size(13.0).color(col));
        ui.add(egui::Label::new(small(foot)).wrap());
    });
}

fn result_card(ui: &mut egui::Ui, r: &RunResult, actions: &mut Vec<Action>) {
    egui::Frame::new()
        .fill(Color32::from_white_alpha(15))
        .corner_radius(CornerRadius::same(10))
        .inner_margin(12)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(
                RichText::new(&r.title)
                    .size(13.0)
                    .strong()
                    .color(if r.is_error { ORANGE } else { Color32::WHITE }),
            );
            if let Some(d) = &r.detail {
                ui.label(small(d));
            }
            if r.can_undo {
                let (u, d) = half_buttons(ui, ("Undo", ButtonKind::Quiet), ("Done", ButtonKind::Quiet));
                if u {
                    actions.push(Action::Undo);
                }
                if d {
                    actions.push(Action::DismissResult);
                }
            } else if big_button(ui, "Done", ButtonKind::Quiet, true) {
                actions.push(Action::DismissResult);
            }
        });
}

fn running(ui: &mut egui::Ui, m: &mut Model, sim: Option<&Sim>, actions: &mut Vec<Action>) {
    let Some(s) = sim else { return };
    map(ui, s);
    ui.add_space(4.0);
    let bin = s.bin_count as f32 / s.bin_capacity.max(1) as f32;
    ui.horizontal(|ui| {
        let w = (ui.available_width() - 18.0) / 2.0;
        ui.spacing_mut().item_spacing.x = 18.0;
        meter(
            ui,
            w,
            "Battery",
            s.battery,
            &format!("{}%", (s.battery * 100.0) as i32),
            Color32::from_rgb(107, 230, 140),
        );
        meter(
            ui,
            w,
            "Bin",
            bin,
            &format!("{}%", (bin.min(1.0) * 100.0) as i32),
            if bin > 0.85 { ORANGE } else { ACCENT },
        );
    });
    ui.horizontal(|ui| {
        let w = (ui.available_width() - 2.0 * ui.spacing().item_spacing.x) / 3.0;
        stat(ui, w, &s.collected.to_string(), &format!("of {} items", m.total));
        stat(ui, w, &fmt_bytes(s.collected_bytes), "collected");
        let t = s.run_time as i32;
        stat(ui, w, &format!("{}:{:02}", t / 60, t % 60), "elapsed");
    });
    controls(ui, m, s, actions);
}

fn meter(ui: &mut egui::Ui, w: f32, title: &str, value: f32, text: &str, tint: Color32) {
    ui.allocate_ui(Vec2::new(w, 30.0), |ui| {
        ui.set_width(w);
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 5.0;
            ui.horizontal(|ui| {
                ui.label(small(title));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(RichText::new(text).size(12.0))
                });
            });
            let (rect, _) = ui.allocate_exact_size(Vec2::new(w, 5.0), egui::Sense::hover());
            ui.painter().rect_filled(rect, 2.5, Color32::from_white_alpha(26));
            let mut f = rect;
            f.set_width(w * value.clamp(0.0, 1.0));
            ui.painter().rect_filled(f, 2.5, tint);
        });
    });
}

fn stat(ui: &mut egui::Ui, w: f32, big: &str, small_text: &str) {
    ui.allocate_ui(Vec2::new(w, 34.0), |ui| {
        ui.set_width(w);
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 1.0;
            ui.label(RichText::new(big).size(15.0).strong());
            ui.label(RichText::new(small_text).size(11.0).color(SECONDARY));
        });
    });
}

fn controls(ui: &mut egui::Ui, m: &mut Model, s: &Sim, actions: &mut Vec<Action>) {
    let selected = m.total.saturating_sub(m.excluded.len());
    let awaiting = s.phase == Phase::Done && m.mode != CleanMode::Tidy && !m.skip_final_click && m.outcome.is_none() && !m.applying;
    if let Some(left) = m.delete_countdown {
        ui.label(RichText::new(format!("Deleting {selected} items in {left}…")).size(13.0).strong());
        ui.label(small("This can't be undone once it starts."));
        if big_button(ui, "Stop and put everything back", ButtonKind::Primary, true) {
            actions.push(Action::CancelCountdown);
        }
    } else if m.applying {
        ui.horizontal(|ui| {
            ui.spinner();
            let what = match m.outcome {
                Some(CleanMode::Delete) => "Deleting…",
                Some(CleanMode::Trash) => "Moving to the Recycle Bin…",
                _ => "Arranging your icons…",
            };
            ui.label(RichText::new(what).size(13.0));
        });
    } else if awaiting {
        decision(ui, m, selected, actions);
    } else if m.real_run && matches!(s.phase, Phase::Done | Phase::Tidying | Phase::Tidied) {
        if s.phase != Phase::Done || (m.outcome.is_none() && m.mode == CleanMode::Tidy) {
            ui.label(RichText::new("Sorting your icons into columns…").size(13.0));
        }
    } else if matches!(s.phase, Phase::Done | Phase::Tidying | Phase::Tidied) {
        let title = match m.outcome {
            Some(CleanMode::Trash) => format!("{} items moved to the Recycle Bin", m.total),
            Some(CleanMode::Delete) => format!("{} items deleted", m.total),
            _ => "Sorted into columns".into(),
        };
        ui.label(RichText::new(title).size(13.0).strong());
        ui.label(small(
            "That was the sample mess, so nothing real changed. Put everything back to finish.",
        ));
        if big_button(ui, "Put everything back", ButtonKind::Primary, true) {
            actions.push(Action::PutBack);
        }
    } else if matches!(s.phase, Phase::PuttingBack | Phase::Leaving | Phase::Finished) {
    } else {
        let (p, st) = half_buttons(
            ui,
            (if s.paused { "▶ Resume" } else { "⏸ Pause" }, ButtonKind::Quiet),
            ("✕ Stop", ButtonKind::Quiet),
        );
        if p {
            actions.push(Action::TogglePause);
        }
        if st {
            actions.push(Action::Stop);
        }
        ui.label(small(if m.real_run {
            "Stopping before the end changes nothing. Esc works too."
        } else {
            "Esc stops and brings your desktop back. Try dragging the robot, or throwing an icon at it."
        }));
    }
}

fn decision(ui: &mut egui::Ui, m: &mut Model, selected: usize, actions: &mut Vec<Action>) {
    let title = if m.mode == CleanMode::Delete {
        format!("Permanently delete {selected} items?")
    } else {
        format!("Move {selected} items to the Recycle Bin?")
    };
    ui.label(RichText::new(title).size(13.0).strong());
    let body = if !m.real_run {
        "This is the sample mess, so nothing real will change.".to_string()
    } else {
        let mut parts = Vec::new();
        if m.file_bytes > 0 {
            parts.push(format!("{} in files", fmt_bytes(m.file_bytes)));
        }
        if m.folder_count > 0 {
            parts.push(format!(
                "{} {}",
                m.folder_count,
                if m.folder_count == 1 { "folder" } else { "folders" }
            ));
        }
        let mut t = if parts.is_empty() {
            String::new()
        } else {
            parts.join(", plus ") + ". "
        };
        t += if m.mode == CleanMode::Delete {
            "This can't be undone."
        } else {
            "You can get them back from the Recycle Bin."
        };
        if m.left_alone > 0 {
            t += &format!(" {} left alone for safety.", m.left_alone);
        }
        t
    };
    ui.label(small(body));
    if m.real_run && m.uses_cloud {
        ui.label(
            RichText::new("Your Desktop syncs with OneDrive, so these will also go from your other devices.")
                .size(12.0)
                .color(ORANGE),
        );
    }
    if m.real_run {
        egui::CollapsingHeader::new(RichText::new("Review items").size(12.0))
            .default_open(m.review_open)
            .show(ui, |ui| {
                egui::ScrollArea::vertical().max_height(170.0).show(ui, |ui| {
                    for (i, name) in &m.review_rows {
                        let mut on = !m.excluded.contains(i);
                        if ui.checkbox(&mut on, RichText::new(name).size(12.0)).changed() {
                            if on {
                                m.excluded.remove(i);
                            } else {
                                m.excluded.insert(*i);
                            }
                        }
                    }
                });
            });
    }
    let go = if m.mode == CleanMode::Delete {
        big_button(ui, "Delete permanently", ButtonKind::Danger, selected > 0)
    } else {
        big_button(ui, "Move to the Recycle Bin", ButtonKind::Primary, selected > 0)
    };
    if go {
        actions.push(Action::Choose(m.mode));
    }
    if big_button(ui, "Put everything back", ButtonKind::Quiet, true) {
        actions.push(Action::PutBack);
    }
}

/// The floor plan, like the one in a real robot's phone app. Draws only what lidar has "seen".
fn map(ui: &mut egui::Ui, s: &Sim) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 190.0), egui::Sense::hover());
    let k = (rect.width() / s.size.x).min(rect.height() / s.size.y);
    let (w, h) = (s.size.x * k, s.size.y * k);
    let o = rect.min + Vec2::new((rect.width() - w) / 2.0, (rect.height() - h) / 2.0);
    let frame = egui::Rect::from_min_size(o, Vec2::new(w, h));
    let p = ui.painter().with_clip_rect(frame);
    let pt = |v: V2| o + Vec2::new(v.x * k, v.y * k);
    p.rect_filled(frame, 8.0, Color32::from_white_alpha(13));
    if s.trail.len() > 1 {
        let pts: Vec<egui::Pos2> = s.trail.iter().map(|&t| pt(t)).collect();
        p.add(egui::Shape::line(
            pts.clone(),
            Stroke::new(s.r * 1.7 * k, ACCENT.gamma_multiply(0.16)),
        ));
        p.add(egui::Shape::line(pts, Stroke::new(1.0, ACCENT.gamma_multiply(0.65))));
    }
    let dock = pt(s.dock_pos + crate::math::v2(0.0, s.r * 1.2));
    p.rect_filled(
        egui::Rect::from_center_size(dock, Vec2::new(20.0, 12.0)),
        3.0,
        Color32::from_white_alpha(191),
    );
    for it in s.items.iter().filter(|it| it.seen && it.on_floor()) {
        p.circle_filled(pt(it.icon.pos), 1.6, kind_color(it.entry.kind));
    }
    let rp = pt(s.pos);
    let rr = (s.r * k).max(4.0);
    p.circle_filled(rp, rr, Color32::WHITE);
    p.line_segment(
        [rp, rp + Vec2::new(s.heading.cos(), s.heading.sin()) * rr],
        Stroke::new(1.5, Color32::BLACK),
    );
    if s.phase == Phase::Scanning {
        p.text(
            frame.min + Vec2::new(8.0, 8.0),
            egui::Align2::LEFT_TOP,
            "Mapping",
            egui::FontId::proportional(11.0),
            ACCENT,
        );
    }
}

fn kind_color(k: Kind) -> Color32 {
    match k {
        Kind::Folder => Color32::from_rgb(102, 179, 255),
        Kind::Image => Color32::from_rgb(255, 184, 102),
        Kind::Video => Color32::from_rgb(255, 115, 128),
        Kind::Document => Color32::from_gray(230),
        Kind::Archive => Color32::from_rgb(204, 153, 255),
        Kind::Audio => Color32::from_rgb(128, 242, 179),
        Kind::Other => Color32::from_gray(153),
    }
}
