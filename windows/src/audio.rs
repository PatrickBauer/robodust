//! Everything you hear is synthesised here: no audio files. Port of Audio.swift onto cpal.

use crate::math::clampf;
use crate::sim::SimAudio;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::f32::consts::PI;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy)]
struct Voice {
    kind: u8,
    t: f32,
    dur: f32,
    f0: f32,
    f1: f32,
    amp: f32,
    delay: f32,
    lp: f32,
}

impl Voice {
    fn new(kind: u8, dur: f32, f0: f32, f1: f32, amp: f32, delay: f32) -> Voice {
        Voice {
            kind,
            t: 0.0,
            dur,
            f0,
            f1,
            amp,
            delay,
            lp: 0.0,
        }
    }
}

struct AtomicF32(AtomicU32);
impl AtomicF32 {
    fn new(v: f32) -> Self {
        AtomicF32(AtomicU32::new(v.to_bits()))
    }
    fn get(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }
    fn set(&self, v: f32) {
        self.0.store(v.to_bits(), Ordering::Relaxed)
    }
}

/// The side the simulation talks to. Cheap to call from the main thread.
pub struct Controls {
    pending: Mutex<Vec<Voice>>,
    motor: AtomicF32,
    load: AtomicF32,
    roar: AtomicF32,
    pub muted: AtomicBool,
    seed: AtomicU32,
}

impl Controls {
    fn enqueue(&self, v: impl IntoIterator<Item = Voice>) {
        if let Ok(mut p) = self.pending.lock() {
            p.extend(v);
        }
    }
    fn rand(&self, a: f32, b: f32) -> f32 {
        let mut s = self.seed.load(Ordering::Relaxed);
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        self.seed.store(s, Ordering::Relaxed);
        a + (b - a) * (s as f32 / u32::MAX as f32)
    }
}

impl SimAudio for Controls {
    fn set_motor(&self, level: f32, load: f32) {
        self.motor.set(level);
        self.load.set(load);
    }
    fn set_roar(&self, level: f32) {
        self.roar.set(level);
    }
    fn ingest(&self, mass: f32) {
        let k = clampf((mass - 1.0) / 5.0, 0.0, 1.0);
        let mut v = vec![Voice::new(
            1,
            0.1 + 0.55 * k,
            3200.0 - 2200.0 * k,
            500.0 - 200.0 * k,
            0.30 + 0.28 * k,
            0.0,
        )];
        // Debris rattling up the tube.
        let rattles = 2 + (k * 7.0) as usize;
        for i in 0..rattles {
            v.push(Voice::new(
                2,
                0.03,
                self.rand(900.0, 3400.0),
                0.0,
                0.10,
                0.05 + i as f32 * self.rand(0.03, 0.07),
            ));
        }
        self.enqueue(v);
    }
    fn tick(&self) {
        self.enqueue([Voice::new(2, 0.025, self.rand(1500.0, 3800.0), 0.0, 0.09, 0.0)]);
    }
    fn chirp(&self, notes: &[(f32, f32)]) {
        let mut at = 0.0;
        let mut v = Vec::new();
        for &(f, d) in notes {
            v.push(Voice::new(0, d + 0.12, f, f, 0.15, at));
            at += d;
        }
        self.enqueue(v);
    }
    fn thud(&self, a: f32) {
        self.enqueue([
            Voice::new(3, 0.26, 118.0, 46.0, 0.85 * a, 0.0),
            Voice::new(1, 0.09, 1400.0, 300.0, 0.26 * a, 0.0),
        ]);
    }
}

/// The audio-thread side.
struct Engine {
    ctl: Arc<Controls>,
    sample_rate: f32,
    voices: Vec<Voice>,
    motor: f32,
    load: f32,
    roar: f32,
    phase: f32,
    phase2: f32,
    phase3: f32,
    lp_a: f32,
    lp_b: f32,
    lp_c: f32,
    flutter: f32,
    noise: u32,
}

impl Engine {
    fn white(&mut self) -> f32 {
        self.noise ^= self.noise << 13;
        self.noise ^= self.noise >> 17;
        self.noise ^= self.noise << 5;
        self.noise as i32 as f32 / 2147483648.0
    }

    /// Fills interleaved frames; every channel gets the same mono signal.
    fn render(&mut self, out: &mut [f32], channels: usize) {
        if let Ok(mut p) = self.ctl.pending.try_lock() {
            self.voices.append(&mut p);
        }
        if self.voices.len() > 40 {
            let extra = self.voices.len() - 40;
            self.voices.drain(0..extra);
        }
        let (mt, lt, rt) = (self.ctl.motor.get(), self.ctl.load.get(), self.ctl.roar.get());
        let muted = self.ctl.muted.load(Ordering::Relaxed);
        let sr = self.sample_rate;
        let dt = 1.0 / sr;
        let two_pi = 2.0 * PI;
        // The Swift version's smoothing constants assume 48 kHz.
        let rate = 48000.0 / sr;
        for frame in out.chunks_mut(channels) {
            self.motor += (mt - self.motor) * 0.00036 * rate;
            self.load += (lt - self.load) * 0.0004 * rate;
            self.roar += (rt - self.roar) * 0.00012 * rate;

            // Suction motor: a whine that sags when a heavy file jams the tube.
            let m = self.motor;
            self.flutter += dt * 7.1;
            let drift = 1.0 + 0.006 * (self.flutter * two_pi).sin();
            let f = (96.0 + 34.0 * m - 26.0 * self.load) * drift;
            self.phase = (self.phase + f * dt).fract();
            self.phase2 = (self.phase2 + f * 2.02 * dt).fract();
            self.phase3 = (self.phase3 + f * 5.97 * dt).fract();
            let hum = (self.phase * two_pi).sin() * 0.40 + (self.phase2 * two_pi).sin() * 0.26 + (self.phase3 * two_pi).sin() * 0.06;

            // Moving air: filtered noise, brighter when flowing freely, duller under load.
            let n = self.white();
            let cut_a = 0.035 + 0.07 * m - 0.05 * self.load;
            self.lp_a += (n - self.lp_a) * cut_a.max(0.005);
            self.lp_b += (self.lp_a - self.lp_b) * 0.5;
            let air = self.lp_b * 1.6;

            // Self-empty blower: a much bigger, lower, rising rush.
            self.lp_c += (n - self.lp_c) * (0.03 + 0.10 * self.roar);
            let roar_s = self.lp_c * 2.6 * self.roar + (self.phase * two_pi * 0.5).sin() * 0.25 * self.roar;

            let mut s = (hum * 0.14 + air * 0.42) * m + roar_s * 0.62;

            let mut j = 0;
            while j < self.voices.len() {
                let v = &mut self.voices[j];
                if v.delay > 0.0 {
                    v.delay -= dt;
                    j += 1;
                    continue;
                }
                let p = (v.t / v.dur).min(1.0);
                match v.kind {
                    0 => {
                        // chime
                        let env = (v.t * 180.0).min(1.0) * (1.0 - p).powf(2.2);
                        s += (v.t * v.f0 * two_pi).sin() * env * v.amp;
                        s += (v.t * v.f0 * 2.0 * two_pi).sin() * env * v.amp * 0.14;
                    }
                    1 => {
                        // gulp: a noise burst closing down
                        let cf = v.f0 + (v.f1 - v.f0) * p;
                        let c = (cf * two_pi / sr).min(0.9);
                        v.lp += (n - v.lp) * c;
                        let env = (v.t * 90.0).min(1.0) * (1.0 - p).powf(1.5);
                        s += v.lp * env * v.amp * 1.6;
                    }
                    2 => {
                        // tick: debris against plastic
                        let env = (1.0 - p).powi(3);
                        s += (v.t * v.f0 * two_pi).sin() * env * v.amp;
                    }
                    3 => {
                        // thud
                        let ff = v.f1 + (v.f0 - v.f1) * (1.0 - p).powi(3);
                        v.lp += ff * dt;
                        s += (v.lp * two_pi).sin() * (1.0 - p).powi(2) * v.amp;
                    }
                    _ => {}
                }
                v.t += dt;
                if v.t >= v.dur {
                    self.voices.remove(j);
                } else {
                    j += 1;
                }
            }
            let g = if muted { 0.0 } else { 0.55 };
            let o = (s * 1.1).tanh() * g;
            for c in frame.iter_mut() {
                *c = o;
            }
        }
    }
}

pub struct Synth {
    pub controls: Arc<Controls>,
    stream: Option<cpal::Stream>,
}

impl Synth {
    pub fn new() -> Synth {
        Synth {
            controls: Arc::new(Controls {
                pending: Mutex::new(Vec::new()),
                motor: AtomicF32::new(0.0),
                load: AtomicF32::new(0.0),
                roar: AtomicF32::new(0.0),
                muted: AtomicBool::new(false),
                seed: AtomicU32::new(0x9E37_79B9),
            }),
            stream: None,
        }
    }

    /// Opens the default output. No sound device is not an error: the robot just works silently.
    pub fn start(&mut self) {
        if self.stream.is_some() {
            return;
        }
        let host = cpal::default_host();
        let Some(device) = host.default_output_device() else { return };
        let Ok(cfg) = device.default_output_config() else { return };
        let channels = cfg.channels() as usize;
        let sample_rate = cfg.sample_rate() as f32;
        let config = cpal::StreamConfig {
            channels: cfg.channels(),
            sample_rate: cfg.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };
        let mut engine = Engine {
            ctl: self.controls.clone(),
            sample_rate,
            voices: Vec::new(),
            motor: 0.0,
            load: 0.0,
            roar: 0.0,
            phase: 0.0,
            phase2: 0.0,
            phase3: 0.0,
            lp_a: 0.0,
            lp_b: 0.0,
            lp_c: 0.0,
            flutter: 0.0,
            noise: 0x12345,
        };
        let err = |e| eprintln!("audio: {e}");
        let stream = match cfg.sample_format() {
            cpal::SampleFormat::F32 => device.build_output_stream(config, move |d: &mut [f32], _| engine.render(d, channels), err, None),
            cpal::SampleFormat::I16 => {
                let mut buf = Vec::new();
                device.build_output_stream(
                    config,
                    move |d: &mut [i16], _| {
                        buf.resize(d.len(), 0.0);
                        engine.render(&mut buf, channels);
                        for (o, s) in d.iter_mut().zip(&buf) {
                            *o = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
                        }
                    },
                    err,
                    None,
                )
            }
            _ => return,
        };
        if let Ok(s) = stream {
            let _ = s.play();
            self.stream = Some(s);
        }
    }

    pub fn stop(&mut self) {
        self.controls.set_motor(0.0, 0.0);
        self.controls.set_roar(0.0);
        self.stream = None;
    }
}
