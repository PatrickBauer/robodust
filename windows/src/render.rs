//! wgpu port of Renderer.swift: the floor, the paper, the dock and the robot.

use crate::math::*;
use crate::sim::{Body, Flight, Phase, Sim};
use crate::sprites::{self, Sprite};
use bytemuck::{Pod, Zeroable};
use image::RgbaImage;
use std::f32::consts::PI;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Globals {
    viewport: V2,
    time: f32,
    pad: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct SpriteGpu {
    center: V2,
    half: V2,
    intake: V2,
    angle: f32,
    scale: f32,
    alpha: f32,
    slice: u32,
    pull: f32,
    agit: f32,
    tint: [f32; 4],
    shadow_offset: V2,
    shadow_alpha: f32,
    pad: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct PartGpu {
    pos: V2,
    size: f32,
    ang: f32,
    color: [f32; 4],
    chip: f32,
    pad: [f32; 3],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct RobotU {
    center: V2,
    radius: f32,
    heading: f32,
    lidar: f32,
    bumper: f32,
    bin_fill: f32,
    led_pulse: f32,
    led: [f32; 4],
    alpha: f32,
    shake_x: f32,
    shake_y: f32,
    lift: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct BrushU {
    center: V2,
    radius: f32,
    angle: f32,
    speed: f32,
    alpha: f32,
    sign: f32,
    pad: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ShadowU {
    center: V2,
    radius: f32,
    strength: f32,
    offset: V2,
    blur: f32,
    kind: f32,
    half_box: V2,
    angle: f32,
    pad: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct DockU {
    center: V2,
    half: V2,
    radius: f32,
    alpha: f32,
    bag: f32,
    glow: f32,
    led_pulse: f32,
    pad: [f32; 3],
    led: [f32; 4],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct LidarU {
    center: V2,
    radius: f32,
    angle: f32,
    alpha: f32,
    pad: [f32; 3],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct StampU {
    center: V2,
    half: V2,
    angle: f32,
    dir: f32,
    pad: [f32; 2],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct FadeU {
    amount: f32,
    pad: [f32; 3],
}

const MAX_SPRITES: usize = 4096;
const MAX_PARTS: usize = 2600;
const GRID_VERTS: u32 = 14 * 14 * 6;
const UNIFORM_STRIDE: usize = 256;
const UNIFORM_SLOTS: usize = 64;

/// Per-draw uniforms for one frame, uploaded together just before submit.
struct Uniforms(Vec<u8>);
impl Uniforms {
    fn push<T: Pod>(&mut self, v: &T) -> u32 {
        let off = self.0.len();
        assert!(off / UNIFORM_STRIDE < UNIFORM_SLOTS, "too many draws in one frame");
        self.0.extend_from_slice(bytemuck::bytes_of(v));
        self.0.resize(off + UNIFORM_STRIDE, 0);
        off as u32
    }
}

pub struct Pipelines {
    bg: wgpu::RenderPipeline,
    track_blur: wgpu::RenderPipeline,
    sprite: wgpu::RenderPipeline,
    sprite_shadow: wgpu::RenderPipeline,
    part: wgpu::RenderPipeline,
    robot: wgpu::RenderPipeline,
    brush: wgpu::RenderPipeline,
    shadow: wgpu::RenderPipeline,
    dock: wgpu::RenderPipeline,
    lidar: wgpu::RenderPipeline,
    stamp: wgpu::RenderPipeline,
    fade: wgpu::RenderPipeline,
}

pub struct Renderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub size_pts: V2,
    pub format: wgpu::TextureFormat,
    p: Pipelines,
    tex_layout: wgpu::BindGroupLayout,
    globals_buf: wgpu::Buffer,
    draw_buf: wgpu::Buffer,
    sprite_buf: wgpu::Buffer,
    part_buf: wgpu::Buffer,
    group0: wgpu::BindGroup,
    track_view: wgpu::TextureView,
    /// Quarter-size blur of the track, redone whenever the track changes.
    blur_view: wgpu::TextureView,
    blur_group: wgpu::BindGroup,
    track_dirty: bool,
    dummy_2d: wgpu::TextureView,
    dummy_arr: wgpu::TextureView,
    bg_group: Option<wgpu::BindGroup>,
    logo_group: wgpu::BindGroup,
    icon_group: Option<wgpu::BindGroup>,
    label_group: Option<wgpu::BindGroup>,
    fade_acc: f32,
    last_stamp: Option<V2>,
}

fn tex_entry(binding: u32, dim: wgpu::TextureViewDimension) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: dim,
            multisampled: false,
        },
        count: None,
    }
}

const PREMUL: wgpu::BlendState = wgpu::BlendState {
    color: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::One,
        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
        operation: wgpu::BlendOperation::Add,
    },
    alpha: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::One,
        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
        operation: wgpu::BlendOperation::Add,
    },
};

impl Renderer {
    /// `format` is the target's format; use a non-sRGB one, the shaders work in display values like the Metal original.
    pub fn new(device: wgpu::Device, queue: wgpu::Queue, size_pts: V2, format: wgpu::TextureFormat) -> Renderer {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("robodust"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders.wgsl").into()),
        });
        let vs_frag = wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT;
        let layout0 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("globals"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: vs_frag,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: vs_frag,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: true,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 4,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 5,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let tex_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("textures"),
            entries: &[
                tex_entry(0, wgpu::TextureViewDimension::D2),
                tex_entry(1, wgpu::TextureViewDimension::D2),
                tex_entry(2, wgpu::TextureViewDimension::D2Array),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("robodust"),
            bind_group_layouts: &[Some(&layout0), Some(&tex_layout)],
            immediate_size: 0,
        });

        let pipe = |vs: &str, fs: &str, format: wgpu::TextureFormat, blend: Option<wgpu::BlendState>, mask: wgpu::ColorWrites| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(vs),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &module,
                    entry_point: Some(vs),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &module,
                    entry_point: Some(fs),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend,
                        write_mask: mask,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let all = wgpu::ColorWrites::ALL;
        let track_fmt = wgpu::TextureFormat::Rgba8Unorm;
        let p = Pipelines {
            bg: pipe("bgVS", "bgFS", format, None, all),
            track_blur: pipe("bgVS", "trackBlurFS", track_fmt, None, all),
            sprite: pipe("spriteVS", "spriteFS", format, Some(PREMUL), all),
            sprite_shadow: pipe("spriteShadowVS", "spriteShadowFS", format, Some(PREMUL), all),
            part: pipe("partVS", "partFS", format, Some(PREMUL), all),
            robot: pipe("robotVS", "robotFS", format, Some(PREMUL), all),
            brush: pipe("brushVS", "brushFS", format, Some(PREMUL), all),
            shadow: pipe("shadowVS", "shadowFS", format, Some(PREMUL), all),
            dock: pipe("dockVS", "dockFS", format, Some(PREMUL), all),
            lidar: pipe("lidarVS", "lidarFS", format, Some(PREMUL), all),
            stamp: pipe("stampVS", "stampFS", track_fmt, None, all),
            fade: pipe(
                "fadeVS",
                "fadeFS",
                track_fmt,
                Some(wgpu::BlendState {
                    color: wgpu::BlendComponent {
                        src_factor: wgpu::BlendFactor::One,
                        dst_factor: wgpu::BlendFactor::One,
                        operation: wgpu::BlendOperation::ReverseSubtract,
                    },
                    alpha: wgpu::BlendComponent::OVER,
                }),
                wgpu::ColorWrites::RED,
            ),
        };

        let buf = |label: &str, size: usize, usage: wgpu::BufferUsages| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: size as u64,
                usage: usage | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        };
        let globals_buf = buf("globals", std::mem::size_of::<Globals>(), wgpu::BufferUsages::UNIFORM);
        let draw_buf = buf("draws", UNIFORM_STRIDE * UNIFORM_SLOTS, wgpu::BufferUsages::UNIFORM);
        let sprite_buf = buf(
            "sprites",
            std::mem::size_of::<SpriteGpu>() * MAX_SPRITES,
            wgpu::BufferUsages::STORAGE,
        );
        let part_buf = buf("particles", std::mem::size_of::<PartGpu>() * MAX_PARTS, wgpu::BufferUsages::STORAGE);
        let linear = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let sprite_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            anisotropy_clamp: 8,
            ..Default::default()
        });
        let group0 = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("globals"),
            layout: &layout0,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: globals_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &draw_buf,
                        offset: 0,
                        size: std::num::NonZeroU64::new(64),
                    }),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&linear),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: sprite_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: part_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: wgpu::BindingResource::Sampler(&sprite_sampler),
                },
            ],
        });

        let track = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("track"),
            size: wgpu::Extent3d {
                width: size_pts.x as u32,
                height: size_pts.y as u32,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: track_fmt,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let track_view = track.create_view(&Default::default());
        let blur = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("track blur"),
            size: wgpu::Extent3d {
                width: (size_pts.x as u32).div_ceil(4).max(1),
                height: (size_pts.y as u32).div_ceil(4).max(1),
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: track_fmt,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let blur_view = blur.create_view(&Default::default());

        let mut r = Renderer {
            dummy_2d: Self::upload_2d(&device, &queue, &RgbaImage::new(1, 1)),
            dummy_arr: Self::upload_array(&device, &queue, &[RgbaImage::new(1, 1)], false),
            logo_group: unsafe_placeholder_group(&device, &tex_layout),
            blur_group: unsafe_placeholder_group(&device, &tex_layout),
            device,
            queue,
            size_pts,
            format,
            p,
            tex_layout,
            globals_buf,
            draw_buf,
            sprite_buf,
            part_buf,
            group0,
            track_view,
            blur_view,
            track_dirty: true,
            bg_group: None,
            icon_group: None,
            label_group: None,
            fade_acc: 0.0,
            last_stamp: None,
        };
        let logo = Self::upload_2d(&r.device, &r.queue, &sprites::logo());
        r.logo_group = r.tex_group(&logo, &logo, &r.dummy_arr);
        r.blur_group = r.tex_group(&r.dummy_2d, &r.track_view, &r.dummy_arr);
        r.clear_track();
        r
    }

    fn tex_group(&self, a: &wgpu::TextureView, b: &wgpu::TextureView, arr: &wgpu::TextureView) -> wgpu::BindGroup {
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.tex_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(a),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(b),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(arr),
                },
            ],
        })
    }

    pub fn clear_track(&mut self) {
        let mut enc = self.device.create_command_encoder(&Default::default());
        {
            let _pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear track"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.track_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.0,
                            g: 0.5,
                            b: 0.0,
                            a: 0.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
        }
        self.queue.submit([enc.finish()]);
        self.last_stamp = None;
        self.track_dirty = true;
    }

    fn upload_2d(device: &wgpu::Device, queue: &wgpu::Queue, img: &RgbaImage) -> wgpu::TextureView {
        Self::upload_array(device, queue, std::slice::from_ref(img), false)
            .texture()
            .create_view(&wgpu::TextureViewDescriptor {
                dimension: Some(wgpu::TextureViewDimension::D2),
                ..Default::default()
            })
    }

    /// All images must share one size. Mip levels are box-filtered on the CPU.
    fn upload_array(device: &wgpu::Device, queue: &wgpu::Queue, images: &[RgbaImage], mipmapped: bool) -> wgpu::TextureView {
        let (w, h) = images[0].dimensions();
        let levels = if mipmapped { 32 - w.max(h).leading_zeros() } else { 1 };
        let tex = device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: images.len() as u32,
            },
            mip_level_count: levels,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        for (layer, img) in images.iter().enumerate() {
            let mut level_img = img.clone();
            for level in 0..levels {
                let (lw, lh) = level_img.dimensions();
                queue.write_texture(
                    wgpu::TexelCopyTextureInfo {
                        texture: &tex,
                        mip_level: level,
                        origin: wgpu::Origin3d {
                            x: 0,
                            y: 0,
                            z: layer as u32,
                        },
                        aspect: wgpu::TextureAspect::All,
                    },
                    level_img.as_raw(),
                    wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(4 * lw),
                        rows_per_image: Some(lh),
                    },
                    wgpu::Extent3d {
                        width: lw,
                        height: lh,
                        depth_or_array_layers: 1,
                    },
                );
                if level + 1 < levels {
                    level_img = halve(&level_img);
                }
            }
        }
        tex.create_view(&wgpu::TextureViewDescriptor {
            dimension: Some(wgpu::TextureViewDimension::D2Array),
            ..Default::default()
        })
    }

    /// The wallpaper, already scaled to the monitor (straight RGB, opaque).
    pub fn set_wallpaper(&mut self, img: &RgbaImage) {
        let wall = Self::upload_2d(&self.device, &self.queue, img);
        self.bg_group = Some(self.tex_group(&wall, &self.blur_view, &self.dummy_arr));
    }

    pub fn set_sprites(&mut self, s: &[Sprite]) {
        let max_layers = self.device.limits().max_texture_array_layers as usize;
        let n = s.len().min(max_layers);
        let icons: Vec<RgbaImage> = s[..n].iter().map(|x| x.icon.clone()).collect();
        let labels: Vec<RgbaImage> = s[..n].iter().map(|x| x.label.clone()).collect();
        if icons.is_empty() {
            return;
        }
        let it = Self::upload_array(&self.device, &self.queue, &icons, true);
        let lt = Self::upload_array(&self.device, &self.queue, &labels, true);
        self.icon_group = Some(self.tex_group(&self.dummy_2d, &self.dummy_2d, &it));
        self.label_group = Some(self.tex_group(&self.dummy_2d, &self.dummy_2d, &lt));
    }

    // MARK: - Frame

    pub fn encode(&mut self, sim: &Sim, target: &wgpu::TextureView, enc: &mut wgpu::CommandEncoder, dt: f32) {
        let mut uni = Uniforms(Vec::with_capacity(UNIFORM_STRIDE * 24));
        let g = Globals {
            viewport: self.size_pts,
            time: sim.t,
            pad: 0.0,
        };
        self.queue.write_buffer(&self.globals_buf, 0, bytemuck::bytes_of(&g));
        self.stamp_track(sim, enc, dt, &mut uni);
        if self.track_dirty {
            self.track_dirty = false;
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("track blur"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.blur_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.p.track_blur);
            pass.set_bind_group(0, &self.group0, &[0]);
            pass.set_bind_group(1, &self.blur_group, &[]);
            pass.draw(0..6, 0..1);
        }

        // Assemble sprite instances: labels first, then icons, things being eaten on top.
        let mut ground: Vec<SpriteGpu> = Vec::with_capacity(sim.items.len());
        let mut ground_labels = Vec::new();
        let mut top = Vec::new();
        let mut top_labels = Vec::new();
        let mut late = Vec::new();
        let intake = sim.intake();
        let icon_half = v2(sprites::ICON_PTS / 2.0, sprites::ICON_PTS / 2.0);
        let label_half = v2(sprites::LABEL_W / 2.0, sprites::LABEL_H / 2.0);
        // Funnels in up close. From far away it shrinks and zips over, or it would smear across the screen.
        let funnel_reach = sim.r * 2.2;
        let funnel = |b: &Body| -> (f32, f32, bool) {
            if !b.ingesting {
                return (0.0, 1.0, true);
            }
            if (intake - b.pos).len() < funnel_reach {
                (b.pull, 1.0, true)
            } else {
                (0.0, 1.0 - b.pull * 0.55, false)
            }
        };
        for it in &sim.items {
            let slice = it.index as u32;
            let flying = it.flight != Flight::None && it.flight_delay <= 0.0;
            if it.flight != Flight::None && it.flight_delay > 0.0 && it.flight != Flight::ToBag && it.in_dock {
                // Queued: still invisible in the bag.
                continue;
            }
            if it.in_bin || (it.in_dock && !flying) {
                continue;
            }
            let far = intake + v2(0.0, 100000.0);
            if !it.icon.gone || flying {
                let a = it.icon.agit;
                let wob = if flying {
                    0.0
                } else {
                    a * 0.13 * (sim.t * (17.0 + it.icon.seed % 7.0) + it.icon.seed).sin()
                };
                let jitter = if flying {
                    V2::ZERO
                } else {
                    v2((sim.t * 33.0 + it.icon.seed).sin(), (sim.t * 29.0 + it.icon.seed * 2.0).cos()) * (a * a * 1.6)
                };
                let squash = 1.0 + it.land * 0.12 * (it.land * 6.0).sin();
                let f = funnel(&it.icon);
                let scale = (if flying { it.flight_scale } else { 1.0 + a * 0.05 }) * squash * f.1;
                let lift = if flying { (it.flight_t * PI).sin() } else { a };
                let tint = if it.ping > 0.0 {
                    [0.45, 0.95, 1.0, it.ping * 0.55]
                } else {
                    [0.0; 4]
                };
                let inst = SpriteGpu {
                    center: it.icon.pos + jitter,
                    half: icon_half,
                    intake: if flying { far } else { intake },
                    angle: it.icon.ang + wob,
                    scale,
                    alpha: 1.0,
                    slice,
                    pull: f.0,
                    agit: if flying || !f.2 { 0.0 } else { a },
                    tint,
                    shadow_offset: v2(2.0, 3.0) + v2(5.0, 9.0) * lift,
                    shadow_alpha: 0.34 * lift.max(0.0),
                    pad: 0.0,
                };
                if flying && it.flight == Flight::ToBag {
                    late.push(inst);
                } else if flying || it.icon.ingesting {
                    top.push(inst);
                } else {
                    ground.push(inst);
                }
            }
            // Label.
            let label_visible = !it.label.gone || flying;
            if label_visible && it.flight != Flight::ToBag {
                let attached = it.label_attached;
                let lpos = if attached {
                    it.icon.pos + v2(0.0, sim.label_offset * if flying { it.flight_scale } else { 1.0 }).rotated(it.icon.ang)
                } else {
                    it.label.pos
                };
                let lang = if attached { it.icon.ang } else { it.label.ang };
                let f = if attached { (0.0, 1.0, true) } else { funnel(&it.label) };
                let scale = (if attached && flying { it.flight_scale } else { 1.0 }) * f.1;
                let a = if !f.2 {
                    0.0
                } else if attached {
                    it.icon.agit * 0.6
                } else {
                    it.label.agit
                };
                let tint = if it.ping > 0.0 {
                    [0.55, 0.97, 1.0, it.ping * 0.7]
                } else {
                    [0.0; 4]
                };
                let inst = SpriteGpu {
                    center: lpos,
                    half: label_half,
                    intake: if flying { far } else { intake },
                    angle: lang,
                    scale,
                    alpha: 1.0,
                    slice,
                    pull: f.0,
                    agit: if flying { 0.0 } else { a },
                    tint,
                    shadow_offset: V2::ZERO,
                    shadow_alpha: 0.0,
                    pad: 0.0,
                };
                if flying || it.label.ingesting {
                    top_labels.push(inst);
                } else {
                    ground_labels.push(inst);
                }
            }
        }

        // Upload all sprite instances in draw order; remember each list's range.
        let (flat, lifted): (Vec<SpriteGpu>, Vec<SpriteGpu>) = ground.into_iter().partition(|s| s.shadow_alpha <= 0.015);
        let lists = [&ground_labels, &flat, &lifted, &top_labels, &top, &late];
        let mut all: Vec<SpriteGpu> = Vec::new();
        let mut ranges = [(0u32, 0u32); 6];
        for (k, l) in lists.iter().enumerate() {
            let start = all.len().min(MAX_SPRITES);
            all.extend(l.iter().copied());
            all.truncate(MAX_SPRITES);
            ranges[k] = (start as u32, all.len() as u32);
        }
        if !all.is_empty() {
            self.queue.write_buffer(&self.sprite_buf, 0, bytemuck::cast_slice(&all));
        }
        let parts = particle_instances(sim);
        if !parts.is_empty() {
            self.queue.write_buffer(&self.part_buf, 0, bytemuck::cast_slice(&parts));
        }

        // Per-draw uniforms, decided up front so the pass can reference their offsets.
        let lidar_off = (sim.scan_active > 0.01).then(|| {
            uni.push(&LidarU {
                center: sim.pos,
                radius: self.size_pts.x.max(self.size_pts.y) * 0.85,
                angle: -PI / 2.0 + sim.scan_sweep,
                alpha: sim.scan_active,
                pad: [0.0; 3],
            })
        });
        let dock_offs = self.dock_uniforms(sim, &mut uni);
        let robot_offs = self.robot_uniforms(sim, &mut uni);
        self.queue.write_buffer(&self.draw_buf, 0, &uni.0);

        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("frame"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        // Wallpaper.
        if let Some(bg) = &self.bg_group {
            pass.set_pipeline(&self.p.bg);
            pass.set_bind_group(0, &self.group0, &[0]);
            pass.set_bind_group(1, bg, &[]);
            pass.draw(0..6, 0..1);
        }
        let draw_sprites = |pass: &mut wgpu::RenderPass, range: (u32, u32), group: &Option<wgpu::BindGroup>, shadows: bool| {
            let Some(group) = group else { return };
            if range.0 == range.1 {
                return;
            }
            pass.set_bind_group(0, &self.group0, &[0]);
            pass.set_bind_group(1, group, &[]);
            if shadows {
                pass.set_pipeline(&self.p.sprite_shadow);
                pass.draw(0..GRID_VERTS, range.0..range.1);
            }
            pass.set_pipeline(&self.p.sprite);
            pass.draw(0..GRID_VERTS, range.0..range.1);
        };
        draw_sprites(&mut pass, ranges[0], &self.label_group, false);
        // Only lifted icons cast a shadow, so the resting ones match Explorer's look exactly.
        draw_sprites(&mut pass, ranges[1], &self.icon_group, false);
        draw_sprites(&mut pass, ranges[2], &self.icon_group, true);
        draw_sprites(&mut pass, ranges[3], &self.label_group, false);
        draw_sprites(&mut pass, ranges[4], &self.icon_group, true);

        // Lidar sweep sits on the floor, under the robot.
        if let Some(off) = lidar_off {
            pass.set_pipeline(&self.p.lidar);
            pass.set_bind_group(0, &self.group0, &[off]);
            pass.set_bind_group(1, &self.logo_group, &[]);
            pass.draw(0..6, 0..1);
        }
        // Dock: shadow, then body.
        pass.set_bind_group(1, &self.logo_group, &[]);
        pass.set_pipeline(&self.p.shadow);
        pass.set_bind_group(0, &self.group0, &[dock_offs.0]);
        pass.draw(0..6, 0..1);
        pass.set_pipeline(&self.p.dock);
        pass.set_bind_group(0, &self.group0, &[dock_offs.1]);
        pass.draw(0..6, 0..1);
        // Particles.
        if !parts.is_empty() {
            pass.set_pipeline(&self.p.part);
            pass.set_bind_group(0, &self.group0, &[0]);
            pass.draw(0..6, 0..parts.len() as u32);
        }
        // Robot: two shadows, two brushes, the shell.
        pass.set_bind_group(1, &self.logo_group, &[]);
        for &off in &robot_offs.shadows {
            pass.set_pipeline(&self.p.shadow);
            pass.set_bind_group(0, &self.group0, &[off]);
            pass.draw(0..6, 0..1);
        }
        for &off in &robot_offs.brushes {
            pass.set_pipeline(&self.p.brush);
            pass.set_bind_group(0, &self.group0, &[off]);
            pass.draw(0..6, 0..1);
        }
        pass.set_pipeline(&self.p.robot);
        pass.set_bind_group(0, &self.group0, &[robot_offs.body]);
        pass.draw(0..6, 0..1);
        draw_sprites(&mut pass, ranges[5], &self.icon_group, false);
    }

    fn dock_uniforms(&self, sim: &Sim, uni: &mut Uniforms) -> (u32, u32) {
        let drop = sim.dock_drop;
        let bounce = 1.0 - (1.0 - drop).powi(3);
        let scale = 1.0 + (1.0 - bounce) * 0.55;
        let alpha = sim.dock_alpha * smooth(0.0, 0.35, drop);
        let shake_k = if sim.phase == Phase::Dropping { sim.shake } else { 0.0 };
        let shake_off = v2((sim.t * 70.0).sin(), (sim.t * 61.0).cos()) * shake_k * 3.0;
        let center = sim.dock_pos + shake_off;
        let r = sim.r * scale;
        let tower_c = center + v2(0.0, r * 1.04);
        let height = 1.0 - bounce;
        let s1 = uni.push(&ShadowU {
            center: tower_c,
            radius: r * 0.3,
            strength: 0.44 * alpha * (1.0 - height * 0.6),
            offset: v2(5.0, 8.0) + v2(40.0, 70.0) * height,
            blur: 20.0 + height * 40.0,
            kind: 1.0,
            half_box: v2(r * 1.3, r * 1.02),
            angle: 0.0,
            pad: 0.0,
        });
        let d = uni.push(&DockU {
            center,
            half: v2(r * 1.36, r * 2.14),
            radius: r,
            alpha,
            bag: sim.bag_fill,
            glow: sim.bag_glow,
            led_pulse: sim.led_pulse,
            pad: [0.0; 3],
            led: [sim.led[0], sim.led[1], sim.led[2], 1.0],
        });
        (s1, d)
    }

    fn robot_uniforms(&self, sim: &Sim, uni: &mut Uniforms) -> RobotOffsets {
        let drop = sim.dock_drop;
        let bounce = 1.0 - (1.0 - drop).powi(3);
        let drop_scale = 1.0 + (1.0 - bounce) * 0.55;
        let lift_k = sim.lift;
        let scale = drop_scale * (1.0 + lift_k * 0.13);
        let r = sim.r * scale;
        let alpha = sim.robot_alpha * smooth(0.0, 0.35, drop);
        let height = (1.0 - bounce) + lift_k * 0.9;
        let mut shake_p = v2((sim.t * 83.0).sin(), (sim.t * 71.0).cos()) * sim.shake * 2.6;
        if sim.picked {
            shake_p = v2((sim.t * 19.0).sin(), (sim.t * 15.0).cos()) * 1.2;
        }
        let pos = sim.pos;
        // Two-part shadow: a tight contact core and a wide soft one.
        let specs = [
            (
                v2(2.0, 3.0) + v2(26.0, 44.0) * height,
                7.0 + 18.0 * height,
                0.40 * (1.0 - height * 0.5),
            ),
            (
                v2(10.0, 16.0) + v2(34.0, 58.0) * height,
                26.0 + 34.0 * height,
                0.30 * (1.0 - height * 0.5),
            ),
        ];
        let shadows = specs.map(|(offset, blur, strength)| {
            uni.push(&ShadowU {
                center: pos,
                radius: r * 0.985,
                strength: strength * alpha,
                offset,
                blur,
                kind: 0.0,
                half_box: V2::ZERO,
                angle: 0.0,
                pad: 0.0,
            })
        });
        // Side brushes reach out from under the shell.
        let (l, rr) = sim.brush_centers();
        let brushes = [(l, 1.0f32), (rr, -1.0f32)].map(|(c, sign)| {
            uni.push(&BrushU {
                center: pos + (c - pos) * scale + shake_p,
                radius: r * 0.56,
                angle: sim.brush_angle,
                speed: sim.brush_speed,
                alpha,
                sign,
                pad: 0.0,
            })
        });
        let body = uni.push(&RobotU {
            center: pos,
            radius: r,
            heading: sim.heading,
            lidar: sim.lidar_angle,
            bumper: sim.bumper,
            bin_fill: sim.bin_count as f32 / sim.bin_capacity.max(1) as f32,
            led_pulse: sim.led_pulse,
            led: [sim.led[0], sim.led[1], sim.led[2], 1.0],
            alpha,
            shake_x: shake_p.x,
            shake_y: shake_p.y,
            lift: lift_k,
        });
        RobotOffsets { shadows, brushes, body }
    }

    fn stamp_track(&mut self, sim: &Sim, enc: &mut wgpu::CommandEncoder, dt: f32, uni: &mut Uniforms) {
        // Very slow fade of the nap, so a run stays visible and then relaxes.
        self.fade_acc += dt;
        let fade = if self.fade_acc > 0.28 {
            self.fade_acc = 0.0;
            Some(uni.push(&FadeU {
                amount: 1.0 / 255.0,
                pad: [0.0; 3],
            }))
        } else {
            None
        };
        let stamp = if sim.suction_on() && sim.v.abs() > 8.0 && !sim.picked {
            // Pattern follows travel direction so opposite passes read as lighter and darker lanes.
            let f = sim.fwd();
            let dir = 0.5
                + 0.5
                    * if f.x.abs() > f.y.abs() {
                        f.x.signum()
                    } else if f.y > 0.0 {
                        0.5
                    } else {
                        -0.5
                    };
            let from = self.last_stamp.unwrap_or(sim.pos);
            let seg = (sim.pos - from).len();
            Some(uni.push(&StampU {
                center: (from + sim.pos) * 0.5 - f * (sim.r * 0.2),
                half: v2(seg * 0.5 + 8.0, sim.r * 0.86),
                angle: sim.heading,
                dir,
                pad: [0.0; 2],
            }))
        } else {
            None
        };
        self.last_stamp = Some(sim.pos);
        if fade.is_none() && stamp.is_none() {
            return;
        }
        self.track_dirty = true;
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("track"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &self.track_view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_bind_group(1, &self.logo_group, &[]);
        if let Some(off) = fade {
            pass.set_pipeline(&self.p.fade);
            pass.set_bind_group(0, &self.group0, &[off]);
            pass.draw(0..6, 0..1);
        }
        if let Some(off) = stamp {
            pass.set_pipeline(&self.p.stamp);
            pass.set_bind_group(0, &self.group0, &[off]);
            pass.draw(0..6, 0..1);
        }
    }

    /// Renders one frame into an offscreen texture and returns it as RGBA (for --dump and tests).
    pub fn render_to_image(&mut self, sim: &Sim, dt: f32, scale: f32) -> RgbaImage {
        let (w, h) = ((self.size_pts.x * scale) as u32, (self.size_pts.y * scale) as u32);
        let tex = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("offscreen"),
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: self.format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = tex.create_view(&Default::default());
        let mut enc = self.device.create_command_encoder(&Default::default());
        self.encode(sim, &view, &mut enc, dt);
        let row = (4 * w).div_ceil(256) * 256;
        let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: (row * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &tex,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buf,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(h),
                },
            },
            wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([enc.finish()]);
        buf.map_async(wgpu::MapMode::Read, .., |_| {});
        let _ = self.device.poll(wgpu::PollType::Wait {
            submission_index: None,
            timeout: None,
        });
        let data = buf.get_mapped_range(..).expect("map");
        let bgra = matches!(self.format, wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb);
        let mut img = RgbaImage::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let i = (y * row + x * 4) as usize;
                let p = &data[i..i + 4];
                *img.get_pixel_mut(x, y) = if bgra {
                    image::Rgba([p[2], p[1], p[0], 255])
                } else {
                    image::Rgba([p[0], p[1], p[2], 255])
                };
            }
        }
        img
    }
}

struct RobotOffsets {
    shadows: [u32; 2],
    brushes: [u32; 2],
    body: u32,
}

fn particle_instances(sim: &Sim) -> Vec<PartGpu> {
    sim.particles
        .iter()
        .take(MAX_PARTS)
        .map(|q| {
            let k = clampf(q.life / q.max_life, 0.0, 1.0);
            let mut c = q.color;
            c[3] *= if q.chip > 0.5 { smooth(0.0, 0.3, k) } else { (k * PI).sin() };
            PartGpu {
                pos: q.pos,
                size: q.size,
                ang: q.ang,
                color: c,
                chip: q.chip,
                pad: [0.0; 3],
            }
        })
        .collect()
}

/// 2x2 box filter, for mip levels.
fn halve(img: &RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let (nw, nh) = ((w / 2).max(1), (h / 2).max(1));
    let mut out = RgbaImage::new(nw, nh);
    for y in 0..nh {
        for x in 0..nw {
            let mut acc = [0u32; 4];
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let p = img.get_pixel((2 * x + dx).min(w - 1), (2 * y + dy).min(h - 1));
                for c in 0..4 {
                    acc[c] += p[c] as u32;
                }
            }
            *out.get_pixel_mut(x, y) = image::Rgba(acc.map(|v| ((v + 2) / 4) as u8));
        }
    }
    out
}

/// A throwaway bind group so the struct can be built before the real logo is uploaded.
fn unsafe_placeholder_group(device: &wgpu::Device, layout: &wgpu::BindGroupLayout) -> wgpu::BindGroup {
    let t = device.create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let v = t.create_view(&Default::default());
    let a = t.create_view(&wgpu::TextureViewDescriptor {
        dimension: Some(wgpu::TextureViewDimension::D2Array),
        ..Default::default()
    });
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&v),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(&v),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::TextureView(&a),
            },
        ],
    })
}
