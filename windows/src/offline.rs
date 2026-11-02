//! Renders a run without any window: same sim and shaders, fixed timestep. Sample items only,
//! so nothing from the real desktop can end up in a frame.

use crate::entries;
use crate::math::*;
use crate::render::Renderer;
use crate::sim::{CleanMode, Phase, Sim};
use crate::sprites;
use image::RgbaImage;

pub struct Options {
    pub dump_times: Vec<f32>,
    pub dump_dir: String,
    pub max_seconds: f32,
    pub mode: CleanMode,
    pub skip: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            dump_times: vec![],
            dump_dir: ".".into(),
            max_seconds: 240.0,
            mode: CleanMode::Trash,
            skip: false,
        }
    }
}

pub fn headless_device() -> (wgpu::Device, wgpu::Queue) {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())).expect("no GPU adapter");
    eprintln!("adapter: {:?}", adapter.get_info().name);
    pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default())).expect("no device")
}

/// Procedural floor for when no wallpaper can be read, and for the headless renderer.
pub fn fallback_wallpaper(w: u32, h: u32) -> RgbaImage {
    let a = [0.13, 0.22, 0.42];
    let b = [0.42, 0.32, 0.5];
    RgbaImage::from_fn(w, h, |x, y| {
        let t = (x as f32 * w as f32 + y as f32 * h as f32) / (w as f32 * w as f32 + h as f32 * h as f32);
        let c = [0, 1, 2].map(|i| ((a[i] + (b[i] - a[i]) * t) * 255.0) as u8);
        image::Rgba([c[0], c[1], c[2], 255])
    })
}

pub fn run(o: Options) {
    let (w, h) = (1920.0f32, 1080.0f32);
    let (device, queue) = headless_device();
    let mut r = Renderer::new(device, queue, v2(w, h), wgpu::TextureFormat::Bgra8Unorm);
    r.set_wallpaper(&fallback_wallpaper(w as u32, h as u32));
    let entries = entries::sample(w, h);
    let t0 = std::time::Instant::now();
    let sprites: Vec<sprites::Sprite> = entries.iter().map(|e| sprites::make(e, None)).collect();
    eprintln!("sprites: {} in {:.2}s", sprites.len(), t0.elapsed().as_secs_f32());
    r.set_sprites(&sprites);
    // Taskbar at the bottom, like Windows.
    let mut s = Sim::new(v2(w, h), v2(0.0, 0.0), v2(w, h - 48.0), entries, sprites::LABEL_OFFSET);
    for (i, sp) in sprites.iter().enumerate() {
        s.items[i].color = sp.average;
    }
    s.mode = o.mode;
    s.skip_final_click = o.skip;
    std::fs::create_dir_all(&o.dump_dir).ok();

    let dt = 1.0 / 60.0;
    let mut times = o.dump_times.clone();
    times.sort_by(f32::total_cmp);
    let mut next = 0;
    let mut frame = 0u32;
    while s.t < o.max_seconds {
        for _ in 0..2 {
            s.step(dt / 2.0);
        }
        frame += 1;
        let due = next < times.len() && s.t >= times[next];
        // The track buffer needs every frame to build up, so render even when not dumping.
        if due {
            let img = r.render_to_image(&s, dt, 1.0);
            let path = format!("{}/frame_{:06.2}.png", o.dump_dir, times[next]);
            img.save(&path).expect("save png");
            eprintln!("{path} phase={:?} collected={}/{}", s.phase, s.collected, s.items.len());
            next += 1;
        } else {
            let mut enc = r.device.create_command_encoder(&Default::default());
            let tex = scratch(&r);
            r.encode(&s, &tex, &mut enc, dt);
            r.queue.submit([enc.finish()]);
            if frame.is_multiple_of(120) {
                let _ = r.device.poll(wgpu::PollType::Wait {
                    submission_index: None,
                    timeout: None,
                });
            }
        }
        if matches!(s.phase, Phase::Done) && s.mode != CleanMode::Tidy && !o.skip && next >= times.len() {
            break;
        }
        if s.phase == Phase::Finished || (next >= times.len() && !times.is_empty()) {
            break;
        }
    }
    eprintln!(
        "ended at t={:.1} phase={:?} collected={}/{} clogs={}",
        s.t,
        s.phase,
        s.collected,
        s.items.len(),
        s.clog_events
    );
}

fn scratch(r: &Renderer) -> wgpu::TextureView {
    thread_local! { static TEX: std::cell::RefCell<Option<wgpu::TextureView>> = const { std::cell::RefCell::new(None) }; }
    TEX.with(|t| {
        t.borrow_mut()
            .get_or_insert_with(|| {
                r.device
                    .create_texture(&wgpu::TextureDescriptor {
                        label: Some("scratch"),
                        size: wgpu::Extent3d {
                            width: r.size_pts.x as u32,
                            height: r.size_pts.y as u32,
                            depth_or_array_layers: 1,
                        },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: wgpu::TextureDimension::D2,
                        format: r.format,
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                        view_formats: &[],
                    })
                    .create_view(&Default::default())
            })
            .clone()
    })
}
