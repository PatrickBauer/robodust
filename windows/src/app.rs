//! Windows, the run lifecycle and the real file actions. Port of App.swift.

use crate::audio::Synth;
use crate::entries::{self, DesktopEntry, Kind};
use crate::math::*;
use crate::platform::{self, DesktopError, Outcome, Screen, Target, Trashed};
use crate::render::Renderer;
use crate::sim::{CleanMode, Phase, Sim, SimAudio};
use crate::sprites::{self, Sprite};
use crate::ui::{self, Action, Model, RunResult, Source, Stage};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::time::{Duration, Instant};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, KeyEvent, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowAttributes, WindowId, WindowLevel};

struct Gpu {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
}

struct Surface {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
}

impl Surface {
    fn new(gpu: &Gpu, window: Arc<Window>) -> Surface {
        let surface = gpu.instance.create_surface(window.clone()).expect("surface");
        let caps = surface.get_capabilities(&gpu.adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| matches!(f, wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Rgba8Unorm))
            .unwrap_or(caps.formats[0]);
        let size = window.inner_size();
        let mut config = surface
            .get_default_config(&gpu.adapter, size.width.max(1), size.height.max(1))
            .expect("surface config");
        config.format = format;
        config.present_mode = wgpu::PresentMode::AutoVsync;
        config.alpha_mode = caps.alpha_modes[0];
        surface.configure(&gpu.device, &config);
        Surface { window, surface, config }
    }
    fn resize(&mut self, gpu: &Gpu, size: PhysicalSize<u32>) {
        if size.width == 0 || size.height == 0 {
            return;
        }
        self.config.width = size.width;
        self.config.height = size.height;
        self.surface.configure(&gpu.device, &self.config);
    }
    fn frame(&mut self, gpu: &Gpu) -> Option<wgpu::SurfaceTexture> {
        match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => Some(t),
            wgpu::CurrentSurfaceTexture::Timeout => {
                crate::debug_log("surface: timeout");
                None
            }
            wgpu::CurrentSurfaceTexture::Occluded => {
                crate::debug_log("surface: occluded");
                None
            }
            other => {
                crate::debug_log(&format!(
                    "surface: {}",
                    if matches!(other, wgpu::CurrentSurfaceTexture::Lost) {
                        "lost"
                    } else {
                        "outdated/other"
                    }
                ));
                self.surface.configure(&gpu.device, &self.config);
                None
            }
        }
    }
}

struct Panel {
    s: Surface,
    ctx: egui::Context,
    state: egui_winit::State,
    renderer: egui_wgpu::Renderer,
    content_height: f32,
}

struct Floor {
    s: Surface,
    renderer: Renderer,
    sim: Sim,
    screen: Screen,
    last: Instant,
    acc: f32,
    cursor: Option<V2>,
    grabbed: Option<usize>,
    last_drag: V2,
    drag_vel: V2,
    finished: bool,
    /// Frames, seconds acquiring, seconds drawing; for --debug.
    stats: (u32, f32, f32),
    stats_since: Instant,
}

struct Prep {
    rx: Receiver<Vec<Sprite>>,
    progress: Arc<AtomicUsize>,
    entries: Vec<DesktopEntry>,
    screen: Screen,
}

enum Undo {
    Recycle(Vec<Trashed>),
    Tidy(Vec<(PathBuf, (f32, f32))>),
}

enum Job {
    Action {
        choice: CleanMode,
        started: Instant,
        excluded: usize,
        rx: Receiver<Outcome>,
    },
    Tidy {
        rx: Receiver<(bool, Result<(), String>)>,
        moves: usize,
        old: Vec<(PathBuf, (f32, f32))>,
    },
    Undo {
        rx: Receiver<RunResult>,
    },
}

pub struct Options {
    pub auto_start: bool,
    pub test_root: Option<PathBuf>,
    pub test_mode: Option<CleanMode>,
}

pub struct App {
    opts: Options,
    gpu: Option<Gpu>,
    panel: Option<Panel>,
    floor: Option<Floor>,
    model: Model,
    synth: Synth,
    hidden: Option<platform::Hidden>,
    prep: Option<Prep>,
    job: Option<Job>,
    pending_finish: Option<(Instant, Vec<usize>)>,
    /// The panel was closed while files were being changed: quit once that's done.
    exit_requested: bool,
    undo: Option<Undo>,
    action_started: bool,
    countdown_until: Option<Instant>,
    last_panel_draw: Instant,
}

fn hwnd_of(w: &Window) -> isize {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match w.window_handle().map(|h| h.as_raw()) {
        Ok(RawWindowHandle::Win32(h)) => h.hwnd.get(),
        _ => 0,
    }
}

impl App {
    pub fn new(opts: Options) -> App {
        let mut model = Model::new();
        if opts.test_root.is_some() {
            model.source = Source::Real;
            model.skip_final_click = true;
            if let Some(m) = opts.test_mode {
                model.mode = m;
            }
        }
        App {
            opts,
            gpu: None,
            panel: None,
            floor: None,
            model,
            synth: Synth::new(),
            hidden: None,
            prep: None,
            job: None,
            pending_finish: None,
            exit_requested: false,
            undo: None,
            action_started: false,
            countdown_until: None,
            last_panel_draw: Instant::now(),
        }
    }

    fn gpu(&mut self, window: &Arc<Window>) -> &Gpu {
        if self.gpu.is_none() {
            let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
            let surface = instance.create_surface(window.clone()).ok();
            let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                compatible_surface: surface.as_ref(),
                ..Default::default()
            }))
            .or_else(|_| {
                // No GPU (a VM, a remote session): Windows' software rasteriser still runs it.
                pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                    compatible_surface: surface.as_ref(),
                    force_fallback_adapter: true,
                    ..Default::default()
                }))
            })
            .expect("no graphics adapter");
            drop(surface);
            let info = adapter.get_info();
            crate::debug_log(&format!("adapter: {} ({:?}, {:?})", info.name, info.backend, info.device_type));
            let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
                // Every desktop item is one layer of the icon and label texture arrays.
                required_limits: wgpu::Limits {
                    max_texture_array_layers: adapter.limits().max_texture_array_layers,
                    ..wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits())
                },
                ..Default::default()
            }))
            .expect("no device");
            self.gpu = Some(Gpu {
                instance,
                adapter,
                device,
                queue,
            });
        }
        self.gpu.as_ref().unwrap()
    }

    // MARK: - Panel window

    fn open_panel(&mut self, el: &ActiveEventLoop) {
        let screen = platform::primary_screen();
        let (wx, wy, ww, wh) = screen.work;
        let w = ui::PANEL_WIDTH;
        let h = 560.0;
        let pos = PhysicalPosition::new(
            wx + ww as i32 - ((w + 28.0) * screen.scale) as i32,
            wy + wh as i32 - ((h + 28.0) * screen.scale) as i32,
        );
        let attrs = WindowAttributes::default()
            .with_title("RoboDust")
            .with_inner_size(LogicalSize::new(w, h))
            .with_position(pos)
            .with_resizable(false)
            .with_enabled_buttons(winit::window::WindowButtons::CLOSE | winit::window::WindowButtons::MINIMIZE)
            .with_window_level(WindowLevel::AlwaysOnTop)
            .with_theme(Some(winit::window::Theme::Dark));
        let window = Arc::new(el.create_window(attrs).expect("panel window"));
        self.gpu(&window);
        let gpu = self.gpu.as_ref().unwrap();
        let s = Surface::new(gpu, window.clone());
        let ctx = egui::Context::default();
        ui::setup_style(&ctx);
        let state = egui_winit::State::new(
            ctx.clone(),
            egui::ViewportId::ROOT,
            &window,
            Some(window.scale_factor() as f32),
            None,
            None,
        );
        let renderer = egui_wgpu::Renderer::new(&gpu.device, s.config.format, egui_wgpu::RendererOptions::default());
        self.panel = Some(Panel {
            s,
            ctx,
            state,
            renderer,
            content_height: h,
        });
        if self.opts.auto_start {
            self.handle(Action::Start, el);
        }
    }

    fn draw_panel(&mut self, el: &ActiveEventLoop) {
        let Some(p) = self.panel.as_mut() else { return };
        let gpu = self.gpu.as_ref().unwrap();
        let input = p.state.take_egui_input(&p.s.window);
        let mut actions = Vec::new();
        let model = &mut self.model;
        let sim = self.floor.as_ref().map(|f| &f.sim);
        let mut height = p.content_height;
        let out = p.ctx.run_ui(input, |ui| {
            let r = ui.scope(|ui| ui::panel(ui, model, sim, &mut actions));
            height = r.response.rect.height();
        });
        p.state.handle_platform_output(&p.s.window, out.platform_output);
        // Grow and shrink with the content, keeping the bottom edge where it is.
        if (height - p.content_height).abs() > 1.0 {
            let scale = p.s.window.scale_factor();
            let old = p.content_height;
            p.content_height = height;
            let _ =
                p.s.window
                    .request_inner_size(LogicalSize::new(ui::PANEL_WIDTH as f64, height as f64));
            if let Ok(pos) = p.s.window.outer_position() {
                let dy = ((height - old) as f64 * scale) as i32;
                p.s.window.set_outer_position(PhysicalPosition::new(pos.x, pos.y - dy));
            }
        }
        let ppp = out.pixels_per_point;
        let jobs = p.ctx.tessellate(out.shapes, ppp);
        for (id, deltas) in &out.textures_delta.set {
            for delta in deltas.iter() {
                p.renderer.update_texture(&gpu.device, &gpu.queue, *id, delta);
            }
        }
        let acquired = p.s.frame(gpu);
        if let Some(frame) = acquired {
            let view = frame.texture.create_view(&Default::default());
            let desc = egui_wgpu::ScreenDescriptor {
                size_in_pixels: [p.s.config.width, p.s.config.height],
                pixels_per_point: ppp,
            };
            let mut enc = gpu.device.create_command_encoder(&Default::default());
            let extra = p.renderer.update_buffers(&gpu.device, &gpu.queue, &mut enc, &jobs, &desc);
            {
                let mut pass = enc
                    .begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("panel"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &view,
                            depth_slice: None,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Clear(wgpu::Color {
                                    r: 0.09,
                                    g: 0.09,
                                    b: 0.09,
                                    a: 1.0,
                                }),
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        ..Default::default()
                    })
                    .forget_lifetime();
                p.renderer.render(&mut pass, &jobs, &desc);
            }
            gpu.queue.submit(extra.into_iter().chain([enc.finish()]));
            gpu.queue.present(frame);
        }
        for id in &out.textures_delta.free {
            p.renderer.free_texture(id);
        }
        self.last_panel_draw = Instant::now();
        for a in actions {
            self.handle(a, el);
        }
    }

    // MARK: - Actions

    fn handle(&mut self, a: Action, el: &ActiveEventLoop) {
        match a {
            Action::Start => self.begin(),
            Action::TogglePause => {
                // Only while the robot is out cleaning: later screens have no Resume button.
                if let Some(f) = self.floor.as_mut()
                    && (f.sim.paused || f.sim.phase < Phase::Done)
                    && self.model.delete_countdown.is_none()
                {
                    f.sim.paused = !f.sim.paused;
                }
            }
            Action::Stop => self.stop_and_restore(),
            Action::PutBack => {
                if let Some(f) = self.floor.as_mut() {
                    f.sim.put_back();
                }
            }
            Action::Choose(c) => self.perform(c),
            Action::CancelCountdown => {
                self.countdown_until = None;
                self.model.delete_countdown = None;
                self.action_started = true;
                if let Some(f) = self.floor.as_mut() {
                    f.sim.put_back();
                }
            }
            Action::Undo => self.run_undo(),
            Action::DismissResult => {
                self.model.result = None;
                self.undo = None;
            }
            Action::SettingsChanged => {
                if self.opts.test_root.is_none() {
                    self.model.save();
                }
            }
        }
        let _ = el;
    }

    fn begin(&mut self) {
        if self.model.stage != Stage::Ready {
            return;
        }
        let screen = platform::primary_screen();
        let size = screen.logical_size();
        self.model.note = None;
        self.model.result = None;
        self.undo = None;
        let entries = if let Some(root) = &self.opts.test_root {
            platform::sandbox(root, size.x)
        } else if self.model.source == Source::Real {
            match platform::read_desktop(&screen) {
                Ok(e) => e,
                Err(DesktopError::NoItems) => {
                    self.model.note = Some("Your desktop is already empty, so here's the sample mess instead.".into());
                    entries::sample(size.x, size.y)
                }
                Err(DesktopError::Denied(why)) => {
                    self.model.note = Some(format!("RoboDust couldn't read your desktop ({why}), so here's the sample mess."));
                    self.model.source = Source::Sample;
                    entries::sample(size.x, size.y)
                }
            }
        } else {
            entries::sample(size.x, size.y)
        };
        // One texture layer per item; a desktop with more items than that runs with the first ones,
        // and the rest are left exactly where they are.
        let mut entries = entries;
        let cap = self
            .gpu
            .as_ref()
            .map_or(256, |g| g.device.limits().max_texture_array_layers as usize);
        if entries.len() > cap {
            self.model.note = Some(format!(
                "Your desktop has {} items. RoboDust takes the first {cap}; the rest stay put.",
                entries.len()
            ));
            entries.truncate(cap);
        }
        self.model.stage = Stage::Preparing;
        self.model.prepared = 0;
        self.model.prepare_total = entries.len();
        let progress = Arc::new(AtomicUsize::new(0));
        let (tx, rx) = channel();
        let list = entries.clone();
        let prog = progress.clone();
        std::thread::spawn(move || {
            platform::com_init();
            // The size Explorer draws icons at, so the shell hands over the same artwork (small sizes
            // have their own, tighter-cropped designs); the sprite scales it up to its own resolution.
            let px = ((sprites::ICON_PTS * screen.scale).round() as u32).max(16);
            let out: Vec<Sprite> = list
                .iter()
                .map(|e| {
                    let icon = if e.image.is_none() { platform::system_icon(e, px) } else { None };
                    let s = sprites::make(e, icon);
                    prog.fetch_add(1, Ordering::Relaxed);
                    s
                })
                .collect();
            let _ = tx.send(out);
        });
        self.prep = Some(Prep {
            rx,
            progress,
            entries,
            screen,
        });
    }

    fn launch(&mut self, el: &ActiveEventLoop, entries: Vec<DesktopEntry>, sprites: Vec<Sprite>, screen: Screen) {
        let size = screen.logical_size();
        let (wx, wy, ww, wh) = screen.work;
        #[allow(unused_mut)]
        let mut attrs = WindowAttributes::default()
            .with_title("RoboDust floor")
            .with_decorations(false)
            .with_resizable(false)
            .with_position(PhysicalPosition::new(wx, wy))
            .with_inner_size(PhysicalSize::new(ww, wh))
            .with_visible(false);
        #[cfg(windows)]
        {
            use winit::platform::windows::WindowAttributesExtWindows;
            attrs = attrs.with_skip_taskbar(true).with_undecorated_shadow(false);
        }
        let window = Arc::new(el.create_window(attrs).expect("floor window"));
        let gpu = self.gpu.as_ref().unwrap();
        let s = Surface::new(gpu, window.clone());
        let mut renderer = Renderer::new(gpu.device.clone(), gpu.queue.clone(), size, s.config.format);
        let wall = platform::wallpaper(&screen).unwrap_or_else(|| crate::offline::fallback_wallpaper(ww, wh));
        renderer.set_wallpaper(&wall);
        renderer.set_sprites(&sprites);
        let mut sim = Sim::new(size, v2(0.0, 0.0), size, entries, sprites::LABEL_OFFSET);
        for (i, sp) in sprites.iter().enumerate() {
            sim.items[i].color = sp.average;
        }
        sim.mode = self.model.mode;
        if let Some(grid) = platform::desktop_grid(&screen) {
            sim.tidy_grid = grid;
        }
        self.model.outcome = None;
        // Handled here, so that it goes through the real file action.
        sim.skip_final_click = false;
        self.action_started = false;
        // Entries with no file behind them (the sample mess) can never reach the file actions.
        let real = sim.items.iter().any(|it| it.entry.path.is_some());
        sim.real_run = real;
        self.model.real_run = real;
        let mode = sim.mode;
        for it in sim.items.iter_mut() {
            it.protected = it.entry.missing || (mode != CleanMode::Tidy && it.entry.protected_reason.is_some());
        }
        let collectable: Vec<&crate::sim::Item> = sim.items.iter().filter(|it| !it.protected).collect();
        self.model.excluded.clear();
        self.model.review_open = false;
        self.model.review_rows = collectable.iter().map(|it| (it.index, it.entry.name.clone())).collect();
        self.model.file_bytes = collectable
            .iter()
            .filter(|it| it.entry.kind != Kind::Folder)
            .map(|it| it.entry.bytes)
            .sum();
        self.model.folder_count = collectable.iter().filter(|it| it.entry.kind == Kind::Folder).count();
        self.model.left_alone = sim.items.len() - collectable.len();
        self.model.uses_cloud = collectable.iter().any(|it| it.entry.cloud);
        self.model.total = collectable.len();
        self.synth.controls.muted.store(self.model.muted, Ordering::Relaxed);
        self.synth.start();
        sim.audio = Some(self.synth.controls.clone() as Arc<dyn SimAudio>);

        // Draw one frame before showing the window, so it never flashes black.
        let mut floor = Floor {
            s,
            renderer,
            sim,
            screen,
            last: Instant::now(),
            acc: 0.0,
            cursor: None,
            grabbed: None,
            last_drag: V2::ZERO,
            drag_vel: V2::ZERO,
            finished: false,
            stats: (0, 0.0, 0.0),
            stats_since: Instant::now(),
        };
        render_floor(gpu, &mut floor, 0.0);
        if self.model.clear_windows {
            let mut keep = vec![hwnd_of(&window)];
            if let Some(p) = &self.panel {
                keep.push(hwnd_of(&p.s.window));
            }
            self.hidden = Some(platform::hide_windows(&keep));
        }
        window.set_visible(true);
        window.focus_window();
        if let Some(p) = &self.panel {
            platform::set_topmost(hwnd_of(&p.s.window), true);
        }
        floor.last = Instant::now();
        self.floor = Some(floor);
        self.model.stage = Stage::Running;
    }

    fn sync(&mut self) {
        let Some(f) = self.floor.as_mut() else { return };
        let s = &mut f.sim;
        if let Some(d) = s.discarded {
            self.model.outcome = Some(d);
        }
        self.synth.controls.muted.store(self.model.muted, Ordering::Relaxed);
        if s.done_once && self.opts.test_root.is_some() {
            s.done_once = false;
        }
        // Skip-the-question path.
        if s.phase == Phase::Done
            && !self.action_started
            && self.model.skip_final_click
            && s.mode != CleanMode::Tidy
            && self.countdown_until.is_none()
        {
            if s.mode == CleanMode::Trash {
                self.perform(CleanMode::Trash);
            } else {
                self.countdown_until = Some(Instant::now() + Duration::from_secs(10));
            }
            return;
        }
        if s.phase == Phase::Tidied && s.real_run && !self.action_started {
            self.action_started = true;
            self.apply_tidy();
        }
        if let Some(until) = self.countdown_until {
            let left = until.saturating_duration_since(Instant::now()).as_secs_f32().ceil() as i32;
            self.model.delete_countdown = Some(left);
            if left <= 0 {
                self.countdown_until = None;
                self.model.delete_countdown = None;
                self.perform(CleanMode::Delete);
            }
        }
    }

    // MARK: - Real actions

    fn perform(&mut self, choice: CleanMode) {
        let Some(f) = self.floor.as_mut() else { return };
        if self.action_started || f.sim.phase != Phase::Done || choice == CleanMode::Tidy {
            return;
        }
        self.action_started = true;
        self.model.outcome = Some(choice);
        f.sim.discard(choice);
        if !f.sim.real_run {
            return;
        }
        let root = self.opts.test_root.clone().unwrap_or_else(platform::desktop_dir);
        let excluded = self.model.excluded.clone();
        let targets: Vec<Target> = f
            .sim
            .items
            .iter()
            .filter(|it| it.in_dock && !it.protected && !excluded.contains(&it.index))
            .filter_map(|it| {
                Some(Target {
                    index: it.index,
                    path: it.entry.path.clone()?,
                    modified: it.entry.modified,
                    position: f.screen.to_screen(it.home),
                })
            })
            .collect();
        self.model.applying = true;
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let o = if choice == CleanMode::Delete {
                platform::fileops::delete(&targets, &root)
            } else {
                platform::fileops::trash(&targets, &root)
            };
            let _ = tx.send(o);
        });
        self.job = Some(Job::Action {
            choice,
            started: Instant::now(),
            excluded: excluded.len(),
            rx,
        });
    }

    fn report(&mut self, choice: CleanMode, o: &Outcome, excluded: usize) {
        let n = o.done.len();
        let mut notes = Vec::new();
        let mut title = if choice == CleanMode::Delete {
            format!("Permanently deleted {n} {}", if n == 1 { "item" } else { "items" })
        } else {
            // Gone without a Recycle Bin record: Windows asked, and the user agreed to delete it for good.
            let nuked = n.saturating_sub(o.trashed.len());
            if nuked > 0 {
                notes.push(format!(
                    "{nuked} didn't fit in the Recycle Bin and {} deleted for good, as you confirmed.",
                    if nuked == 1 { "was" } else { "were" }
                ));
            }
            let moved = n - nuked;
            format!("Moved {moved} {} to the Recycle Bin", if moved == 1 { "item" } else { "items" })
        };
        if !o.failed.is_empty() {
            notes.push(format!(
                "{} couldn't be {} and stayed on your desktop.",
                o.failed.len(),
                if choice == CleanMode::Delete { "deleted" } else { "moved" }
            ));
        }
        if excluded > 0 {
            notes.push(format!("{excluded} kept, as you chose."));
        }
        if self.model.left_alone > 0 {
            notes.push(format!("{} left alone for safety.", self.model.left_alone));
        }
        if n == 0 {
            title = "Nothing was changed".into();
        }
        if choice == CleanMode::Trash && !o.trashed.is_empty() {
            self.undo = Some(Undo::Recycle(o.trashed.clone()));
        }
        self.model.result = Some(RunResult {
            title,
            detail: (!notes.is_empty()).then(|| notes.join(" ")),
            can_undo: self.undo.is_some(),
            is_error: n == 0 && !o.failed.is_empty(),
        });
    }

    fn apply_tidy(&mut self) {
        let Some(f) = self.floor.as_ref() else { return };
        self.model.applying = true;
        let placed: Vec<&crate::sim::Item> = f.sim.items.iter().filter(|it| !it.protected && it.entry.path.is_some()).collect();
        let moves: Vec<(PathBuf, (f32, f32))> = placed
            .iter()
            .map(|it| (it.entry.path.clone().unwrap(), f.screen.to_screen(it.rest)))
            .collect();
        let old: Vec<(PathBuf, (f32, f32))> = placed
            .iter()
            .map(|it| (it.entry.path.clone().unwrap(), f.screen.to_screen(it.home)))
            .collect();
        let n = moves.len();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let free = platform::fileops::desktop_is_freeform();
            let r = if free { platform::fileops::set_positions(&moves) } else { Ok(()) };
            let _ = tx.send((free, r));
        });
        self.job = Some(Job::Tidy { rx, moves: n, old });
    }

    fn run_undo(&mut self) {
        let Some(u) = self.undo.take() else { return };
        self.model.result = Some(RunResult::plain(match u {
            Undo::Recycle(_) => "Bringing items back…",
            Undo::Tidy(_) => "Putting icons back…",
        }));
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let r = match u {
                Undo::Recycle(items) => {
                    let n = platform::fileops::undo_trash(&items);
                    RunResult {
                        title: format!("Brought back {n} {}", if n == 1 { "item" } else { "items" }),
                        detail: (n < items.len()).then(|| format!("{} are still in the Recycle Bin.", items.len() - n)),
                        can_undo: false,
                        is_error: false,
                    }
                }
                Undo::Tidy(old) => match platform::fileops::set_positions(&old) {
                    Ok(()) => RunResult::plain("Icons are back where they were"),
                    Err(_) => RunResult {
                        title: "Some icons didn't move back".into(),
                        detail: Some("Explorer didn't accept every move. No files were changed.".into()),
                        can_undo: false,
                        is_error: true,
                    },
                },
            };
            let _ = tx.send(r);
        });
        self.job = Some(Job::Undo { rx });
    }

    fn poll_jobs(&mut self) {
        if let Some((at, _)) = &self.pending_finish
            && Instant::now() >= *at
        {
            let (_, back) = self.pending_finish.take().unwrap();
            self.model.applying = false;
            if let Some(f) = self.floor.as_mut() {
                f.sim.finish_after_action(&back);
            }
        }
        let Some(job) = self.job.take() else { return };
        match job {
            Job::Action {
                choice,
                started,
                excluded,
                rx,
            } => match rx.try_recv() {
                Ok(o) => {
                    self.report(choice, &o, excluded);
                    let failed: Vec<usize> = o.failed.iter().map(|f| f.0).collect();
                    let back: Vec<usize> = self
                        .floor
                        .as_ref()
                        .map(|f| {
                            f.sim
                                .items
                                .iter()
                                .filter(|it| it.in_dock && (failed.contains(&it.index) || self.model.excluded.contains(&it.index)))
                                .map(|it| it.index)
                                .collect()
                        })
                        .unwrap_or_default();
                    // Let the bag finish draining, and give Explorer time to redraw beneath the floor.
                    let wait = Duration::from_secs_f32((1.5 - started.elapsed().as_secs_f32()).max(0.0) + 0.7);
                    self.pending_finish = Some((Instant::now() + wait, back));
                }
                Err(TryRecvError::Empty) => {
                    self.job = Some(Job::Action {
                        choice,
                        started,
                        excluded,
                        rx,
                    })
                }
                Err(TryRecvError::Disconnected) => {
                    self.model.result = Some(worker_died("Something went wrong while changing your files"));
                    self.pending_finish = Some((Instant::now() + Duration::from_millis(500), Vec::new()));
                }
            },
            Job::Tidy { rx, moves, old } => match rx.try_recv() {
                Ok((free, r)) => {
                    self.model.applying = false;
                    self.model.result = Some(if !free {
                        RunResult {
                            title: "Your desktop wasn't sorted".into(),
                            detail: Some("Explorer is arranging your icons automatically. To use Tidy up, right-click the desktop, open View and turn off Auto arrange icons.".into()),
                            can_undo: false,
                            is_error: true,
                        }
                    } else if r.is_err() {
                        // Some icons may have moved anyway, so Undo stays on offer.
                        self.undo = Some(Undo::Tidy(old));
                        RunResult {
                            title: "Tidy up didn't finish".into(),
                            detail: Some(
                                "Explorer didn't accept every move. No files were changed, and Undo puts the icons that moved back.".into(),
                            ),
                            can_undo: true,
                            is_error: true,
                        }
                    } else {
                        platform::fileops::append_log(&format!("tidy: arranged {moves} icons"));
                        self.undo = Some(Undo::Tidy(old));
                        RunResult {
                            title: format!("Sorted {moves} items into columns"),
                            detail: Some("Only the icons moved. Your files are exactly where they were.".into()),
                            can_undo: true,
                            is_error: false,
                        }
                    });
                    self.pending_finish = Some((Instant::now() + Duration::from_millis(500), Vec::new()));
                }
                Err(TryRecvError::Empty) => self.job = Some(Job::Tidy { rx, moves, old }),
                Err(TryRecvError::Disconnected) => {
                    self.model.result = Some(worker_died("Tidy up didn't finish"));
                    self.pending_finish = Some((Instant::now() + Duration::from_millis(500), Vec::new()));
                }
            },
            Job::Undo { rx } => match rx.try_recv() {
                Ok(r) => self.model.result = Some(r),
                Err(TryRecvError::Empty) => self.job = Some(Job::Undo { rx }),
                Err(TryRecvError::Disconnected) => self.model.result = Some(worker_died("Undo didn't finish")),
            },
        }
        // A job just ended: the panel stops its periodic redraw once nothing runs, so show the result now.
        if self.job.is_none()
            && let Some(p) = &self.panel
        {
            p.s.window.request_redraw();
        }
    }

    // MARK: - Ending a run

    fn stop_and_restore(&mut self) {
        if self.model.applying {
            return;
        }
        self.countdown_until = None;
        self.model.delete_countdown = None;
        self.teardown();
    }

    /// Files are being changed (or put back) right now.
    fn busy(&self) -> bool {
        self.model.applying || self.job.is_some() || self.pending_finish.is_some()
    }

    /// Removing the floor is the whole restore: the real desktop was never changed.
    fn teardown(&mut self) {
        self.synth.stop();
        if let Some(f) = self.floor.take() {
            f.s.window.set_visible(false);
        }
        if let Some(h) = self.hidden.take() {
            platform::restore_windows(h);
        }
        self.prep = None;
        self.model.stage = Stage::Ready;
        // Nothing runs any more, so the panel's periodic redraw stops: show the new stage now.
        if let Some(p) = &self.panel {
            p.s.window.request_redraw();
        }
    }
}

fn render_floor(gpu: &Gpu, f: &mut Floor, dt: f32) {
    let t0 = Instant::now();
    let Some(frame) = f.s.frame(gpu) else { return };
    let t1 = Instant::now();
    let view = frame.texture.create_view(&Default::default());
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    f.renderer.encode(&f.sim, &view, &mut enc, dt);
    gpu.queue.submit([enc.finish()]);
    gpu.queue.present(frame);
    f.stats.0 += 1;
    f.stats.1 += (t1 - t0).as_secs_f32();
    f.stats.2 += t1.elapsed().as_secs_f32();
    if f.stats_since.elapsed() >= Duration::from_secs(2) {
        let n = f.stats.0.max(1) as f32;
        crate::debug_log(&format!(
            "floor: {} frames in {:.1}s, acquire {:.1} ms, draw+present {:.1} ms, phase {:?}",
            f.stats.0,
            f.stats_since.elapsed().as_secs_f32(),
            f.stats.1 / n * 1000.0,
            f.stats.2 / n * 1000.0,
            f.sim.phase
        ));
        f.stats = (0, 0.0, 0.0);
        f.stats_since = Instant::now();
    }
}

impl App {
    /// Advances the simulation by the time since the last frame and draws the floor.
    fn tick_floor(&mut self) {
        let Some(f) = self.floor.as_mut() else { return };
        if f.finished {
            return;
        }
        let gpu = self.gpu.as_ref().unwrap();
        let now = Instant::now();
        // Slow frames (software rendering in a VM or over Remote Desktop) still keep real time, up
        // to a quarter second per frame; longer stalls are dropped rather than fast-forwarded.
        let dt = now.duration_since(f.last).as_secs_f32().min(0.25);
        f.last = now;
        f.acc += dt;
        let h = 1.0 / 120.0;
        f.sim.mouse = if f.sim.picked { None } else { f.cursor };
        f.sim.lift += ((if f.sim.picked { 1.0 } else { 0.0 }) - f.sim.lift) * (dt * 11.0).min(1.0);
        let mut steps = 0;
        while f.acc >= h && steps < 30 {
            f.sim.step(h);
            f.acc -= h;
            steps += 1;
        }
        if steps == 30 {
            f.acc = 0.0;
        }
        render_floor(gpu, f, dt);
        if f.sim.phase == Phase::Finished {
            f.finished = true;
            self.teardown();
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.panel.is_none() {
            self.open_panel(el);
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        let is_panel = self.panel.as_ref().is_some_and(|p| p.s.window.id() == id);
        let is_floor = self.floor.as_ref().is_some_and(|f| f.s.window.id() == id);
        if is_panel {
            let p = self.panel.as_mut().unwrap();
            let resp = p.state.on_window_event(&p.s.window, &event);
            if resp.repaint {
                p.s.window.request_redraw();
            }
        }
        // Keys work in both windows; nothing interrupts a file action.
        if let WindowEvent::KeyboardInput {
            event:
                KeyEvent {
                    logical_key,
                    state: ElementState::Pressed,
                    repeat: false,
                    ..
                },
            ..
        } = &event
            && self.floor.is_some()
            && !self.model.applying
        {
            match logical_key {
                Key::Named(NamedKey::Escape) => self.stop_and_restore(),
                Key::Named(NamedKey::Space) if is_floor => self.handle(Action::TogglePause, el),
                _ => {}
            }
        }
        match event {
            WindowEvent::CloseRequested if is_panel => {
                // Quitting mid-batch would cut the file action off and leave windows minimised.
                if self.busy() {
                    self.exit_requested = true;
                } else {
                    self.stop_and_restore();
                    el.exit();
                }
            }
            WindowEvent::Resized(size) => {
                let gpu = self.gpu.as_ref().unwrap();
                if is_panel {
                    self.panel.as_mut().unwrap().s.resize(gpu, size);
                } else if is_floor {
                    self.floor.as_mut().unwrap().s.resize(gpu, size);
                }
            }
            WindowEvent::RedrawRequested if is_panel => self.draw_panel(el),
            WindowEvent::RedrawRequested if is_floor => self.tick_floor(),
            WindowEvent::CursorMoved { position, .. } if is_floor => {
                let f = self.floor.as_mut().unwrap();
                let p = v2(position.x as f32 / f.screen.scale, position.y as f32 / f.screen.scale);
                f.cursor = Some(p);
                if f.sim.picked {
                    f.sim.drag_robot_to(p);
                } else if let Some(g) = f.grabbed {
                    f.sim.items[g].icon.pos = p;
                    f.drag_vel = f.drag_vel * 0.6 + (p - f.last_drag) * 60.0 * 0.4;
                    f.last_drag = p;
                }
            }
            WindowEvent::CursorLeft { .. } if is_floor => self.floor.as_mut().unwrap().cursor = None,
            WindowEvent::MouseInput {
                state,
                button: MouseButton::Left,
                ..
            } if is_floor => {
                let f = self.floor.as_mut().unwrap();
                let Some(p) = f.cursor else { return };
                match state {
                    ElementState::Pressed => {
                        if f.sim.hit_robot(p) {
                            f.sim.pick_up();
                        } else if let Some(i) = f.sim.hit_item(p)
                            && !f.sim.items[i].icon.ingesting
                        {
                            f.grabbed = Some(i);
                            f.sim.items[i].grabbed = true;
                            f.last_drag = p;
                            f.drag_vel = V2::ZERO;
                        }
                    }
                    ElementState::Released => {
                        if f.sim.picked {
                            f.sim.drop_robot();
                        }
                        if let Some(g) = f.grabbed.take() {
                            let it = &mut f.sim.items[g];
                            it.grabbed = false;
                            it.icon.vel = f.drag_vel;
                            it.icon.ang_v = f.drag_vel.x * 0.006;
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        // Sprites finished building: lay the floor.
        if let Some(prep) = &self.prep {
            self.model.prepared = prep.progress.load(Ordering::Relaxed);
            match prep.rx.try_recv() {
                Ok(sprites) => {
                    let prep = self.prep.take().unwrap();
                    self.launch(el, prep.entries, sprites, prep.screen);
                }
                Err(TryRecvError::Disconnected) => {
                    // The sprite thread died (no usable font, say): back to the start, not stuck.
                    self.prep = None;
                    self.model.stage = Stage::Ready;
                    self.model.note = Some("RoboDust couldn't draw your icons, so it didn't start.".into());
                }
                Err(TryRecvError::Empty) => {}
            }
        }
        self.poll_jobs();
        if self.exit_requested && !self.busy() {
            self.teardown();
            el.exit();
            return;
        }
        self.sync();
        let running = self.floor.is_some() || self.prep.is_some() || self.job.is_some() || self.pending_finish.is_some();
        // Drawn from here rather than on RedrawRequested: Windows hands out WM_PAINT only when the
        // queue is idle, and with the panel repainting too the floor's paints got starved.
        self.tick_floor();
        // The panel shows live stats while running; otherwise it only redraws on input.
        if let Some(p) = &self.panel
            && (running && self.last_panel_draw.elapsed() > Duration::from_millis(66))
        {
            p.s.window.request_redraw();
        }
        if running {
            el.set_control_flow(ControlFlow::Poll);
        } else {
            el.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(250)));
        }
    }
}

/// A file worker that stopped without an answer. What it managed to do is in the history log.
fn worker_died(title: &str) -> RunResult {
    RunResult {
        title: title.into(),
        detail: Some(
            "RoboDust lost track of what happened. Every change it made is listed in %LOCALAPPDATA%\\RoboDust\\history.log.".into(),
        ),
        can_undo: false,
        is_error: true,
    }
}
