//! The robot, the dock and every piece of paper on the floor. A straight port of Sim.swift.

use crate::entries::{DesktopEntry, Kind};
use crate::math::*;
use std::f32::consts::PI;
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanMode {
    Tidy,
    Trash,
    Delete,
}

impl CleanMode {
    pub fn index(self) -> i32 {
        match self {
            CleanMode::Tidy => 0,
            CleanMode::Trash => 1,
            CleanMode::Delete => 2,
        }
    }
    pub fn from_index(i: i32) -> Option<CleanMode> {
        Some(match i {
            0 => CleanMode::Tidy,
            1 => CleanMode::Trash,
            2 => CleanMode::Delete,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Phase {
    Dropping,
    Undocking,
    Scanning,
    Cleaning,
    Hunting,
    Returning,
    Docking,
    Emptying,
    Done,
    Tidying,
    Tidied,
    PuttingBack,
    Leaving,
    Finished,
}

/// One moving sheet of paper: an icon, or the label that tears off it.
#[derive(Clone, Copy, Default)]
pub struct Body {
    pub pos: V2,
    pub vel: V2,
    pub ang: f32,
    pub ang_v: f32,
    pub agit: f32,
    pub pull: f32,
    pub ingesting: bool,
    pub gone: bool,
    pub seed: f32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Flight {
    None,
    ToBag,
    ToHome,
    ToTidy,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Part {
    Icon,
    Label,
}

pub struct Item {
    pub index: usize,
    pub entry: DesktopEntry,
    pub home: V2,
    pub mass: f32,
    pub ingest_time: f32,
    pub color: [f32; 3],
    pub icon: Body,
    pub label: Body,
    pub label_attached: bool,
    pub label_lost: f32,
    pub ping: f32,
    pub seen: bool,
    pub in_bin: bool,
    pub in_dock: bool,
    pub grabbed: bool,
    pub flight: Flight,
    pub flight_from: V2,
    pub flight_to: V2,
    pub flight_t: f32,
    pub flight_delay: f32,
    pub flight_dur: f32,
    pub flight_scale: f32,
    pub flight_spin: f32,
    pub land: f32,
    pub rest: V2,
    pub protected: bool,
}

impl Item {
    fn new(index: usize, entry: DesktopEntry, label_offset: f32) -> Item {
        let mb = entry.bytes.max(1) as f32 / 1_000_000.0;
        let mass = 1.0 + 5.0 * clampf((1.0 + mb).log10() / 4.0, 0.0, 1.0);
        let c = entry.center;
        Item {
            index,
            home: c,
            rest: c,
            mass,
            ingest_time: 0.42 + 0.22 * (mass - 1.0),
            color: [0.6, 0.6, 0.6],
            icon: Body {
                pos: c,
                seed: index as f32 * 1.618,
                ..Default::default()
            },
            label: Body {
                pos: c + v2(0.0, label_offset),
                seed: index as f32 * 2.414,
                ..Default::default()
            },
            entry,
            label_attached: true,
            label_lost: 0.0,
            ping: 0.0,
            seen: false,
            in_bin: false,
            in_dock: false,
            grabbed: false,
            flight: Flight::None,
            flight_from: V2::ZERO,
            flight_to: V2::ZERO,
            flight_t: 0.0,
            flight_delay: 0.0,
            flight_dur: 1.0,
            flight_scale: 1.0,
            flight_spin: 0.0,
            land: 0.0,
            protected: false,
        }
    }
    pub fn on_floor(&self) -> bool {
        !self.in_bin && !self.in_dock && self.flight == Flight::None && !self.icon.gone && !self.protected
    }
    fn body(&mut self, p: Part) -> &mut Body {
        match p {
            Part::Icon => &mut self.icon,
            Part::Label => &mut self.label,
        }
    }
}

#[derive(Clone, Copy)]
pub struct Particle {
    pub pos: V2,
    pub vel: V2,
    pub life: f32,
    pub max_life: f32,
    pub size: f32,
    pub color: [f32; 4],
    pub chip: f32,
    pub ang: f32,
}

pub trait SimAudio: Send + Sync {
    fn set_motor(&self, level: f32, load: f32);
    fn set_roar(&self, level: f32);
    fn ingest(&self, mass: f32);
    fn tick(&self);
    fn chirp(&self, notes: &[(f32, f32)]);
    fn thud(&self, amount: f32);
}

#[derive(Clone, Copy)]
struct Maneuver {
    reverse: f32,
    turn: f32,
    dir: f32,
}

pub struct Sim {
    pub size: V2,
    pub wall_min: V2,
    pub wall_max: V2,
    /// Tidy layout: centre of the first cell and the cell pitch. The platform sets Explorer's own
    /// icon grid, so the columns the robot lays out are the ones Explorer keeps.
    pub tidy_grid: (V2, V2),
    pub r: f32,
    pub speed_scale: f32,
    pub label_offset: f32,

    pub pos: V2,
    pub heading: f32,
    pub v: f32,
    pub w: f32,
    pub brush_angle: f32,
    pub brush_speed: f32,
    pub lidar_angle: f32,
    pub lidar_speed: f32,
    pub bumper: f32,
    pub lift: f32,
    pub picked: bool,
    pub shake: f32,
    pub heavy: f32,
    pub led: [f32; 3],
    pub led_pulse: f32,

    pub dock_pos: V2,
    pub dock_out: V2,
    pub dock_drop: f32,
    pub dock_alpha: f32,
    pub robot_alpha: f32,
    pub bag_fill: f32,
    pub bag_glow: f32,

    pub items: Vec<Item>,
    pub particles: Vec<Particle>,
    pub phase: Phase,
    pub mode: CleanMode,
    pub skip_final_click: bool,
    pub real_run: bool,
    pub discarded: Option<CleanMode>,
    pub draining: bool,
    pub paused: bool,
    pub t: f32,
    pub phase_t: f32,
    pub scan_sweep: f32,
    pub scan_active: f32,
    pub bin_count: usize,
    pub bin_bytes: i64,
    pub collected: usize,
    pub collected_bytes: i64,
    pub bin_capacity: usize,
    pub battery: f32,
    pub distance: f32,
    pub run_time: f32,
    pub status: String,
    pub mouse: Option<V2>,
    pub trail: Vec<V2>,
    last_bump: f32,
    maneuver: Option<Maneuver>,

    path: Vec<V2>,
    path_i: usize,
    waypoint_t: f32,
    hunt_target: Option<usize>,
    hunt_t: f32,
    finishing: bool,
    was_emptying_mid_run: bool,
    first_stop: bool,
    pub clog_events: usize,
    dock_aligned: bool,
    swallowing: usize,

    pub audio: Option<Arc<dyn SimAudio>>,
    rng: SeededRng,
    tick_budget: f32,
    pub done_once: bool,

    empty_duration: f32,
    empty_queue: Vec<usize>,
    empty_acc: f32,
    empty_rate: f32,
}

const ALL_STILL: [Phase; 3] = [Phase::Done, Phase::Tidied, Phase::Finished];

impl Sim {
    pub fn new(size: V2, visible_min: V2, visible_max: V2, entries: Vec<DesktopEntry>, label_offset: f32) -> Sim {
        let r = 92.0;
        let items: Vec<Item> = entries
            .into_iter()
            .enumerate()
            .map(|(i, e)| Item::new(i, e, label_offset))
            .collect();
        let dx = Sim::best_dock_x(&items, size.x);
        let dock_pos = v2(dx, visible_max.y - r * 2.08 - 6.0);
        let n = items.len();
        Sim {
            size,
            wall_min: visible_min,
            wall_max: visible_max,
            tidy_grid: (v2(46.0, visible_min.y + 50.0), v2(84.0, 96.0)),
            r,
            speed_scale: 1.0 + (n as f32 / 300.0).min(0.45),
            label_offset,
            pos: dock_pos,
            heading: -PI / 2.0,
            v: 0.0,
            w: 0.0,
            brush_angle: 0.0,
            brush_speed: 0.0,
            lidar_angle: 0.0,
            lidar_speed: 0.0,
            bumper: 0.0,
            lift: 0.0,
            picked: false,
            shake: 0.0,
            heavy: 0.0,
            led: [0.2, 0.85, 1.0],
            led_pulse: 0.0,
            dock_pos,
            dock_out: v2(0.0, -1.0),
            dock_drop: 0.0,
            dock_alpha: 1.0,
            robot_alpha: 1.0,
            bag_fill: 0.0,
            bag_glow: 0.0,
            items,
            particles: Vec::with_capacity(2500),
            phase: Phase::Dropping,
            mode: CleanMode::Trash,
            skip_final_click: false,
            real_run: false,
            discarded: None,
            draining: false,
            paused: false,
            t: 0.0,
            phase_t: 0.0,
            scan_sweep: 0.0,
            scan_active: 0.0,
            bin_count: 0,
            bin_bytes: 0,
            collected: 0,
            collected_bytes: 0,
            bin_capacity: if n > 40 { (n as f32 * 0.55).ceil() as usize } else { n + 1 },
            battery: 1.0,
            distance: 0.0,
            run_time: 0.0,
            status: "Warming up".into(),
            mouse: None,
            trail: Vec::new(),
            last_bump: -10.0,
            maneuver: None,
            path: Vec::new(),
            path_i: 0,
            waypoint_t: 0.0,
            hunt_target: None,
            hunt_t: 0.0,
            finishing: false,
            was_emptying_mid_run: false,
            first_stop: true,
            clog_events: 0,
            dock_aligned: false,
            swallowing: 0,
            audio: None,
            rng: SeededRng::new(7),
            tick_budget: 0.0,
            done_once: false,
            empty_duration: 3.6,
            empty_queue: Vec::new(),
            empty_acc: 0.0,
            empty_rate: 1.0,
        }
    }

    /// Puts the dock on the emptiest stretch of the bottom wall, near the middle.
    fn best_dock_x(items: &[Item], width: f32) -> f32 {
        // The panel sits in the bottom-right corner on Windows (400 pt wide with its margin);
        // keep the dock out from under it.
        let right = width - 300.0 - 240.0;
        let mut best = (width / 2.0).min(right);
        let mut best_score = f32::INFINITY;
        let mut x = 300.0;
        while x < right {
            let mut score = (x - width / 2.0).abs() * 0.002;
            score += items.iter().filter(|it| (it.home.x - x).abs() < 170.0).count() as f32;
            if score < best_score {
                best_score = score;
                best = x;
            }
            x += 60.0;
        }
        best
    }

    pub fn fwd(&self) -> V2 {
        v2(self.heading.cos(), self.heading.sin())
    }
    pub fn side(&self) -> V2 {
        self.fwd().perp()
    }
    pub fn intake(&self) -> V2 {
        self.pos + self.fwd() * (self.r * 0.80)
    }
    pub fn brush_centers(&self) -> (V2, V2) {
        let a = self.fwd() * (self.r * 0.62);
        let s = self.side() * (self.r * 0.72);
        (self.pos + a + s, self.pos + a - s)
    }
    pub fn remaining(&self) -> usize {
        self.items
            .iter()
            .filter(|it| !it.protected && !it.icon.gone && !it.in_bin && !it.in_dock)
            .count()
    }

    fn rand(&mut self, a: f32, b: f32) -> f32 {
        self.rng.range(a, b)
    }

    fn set_phase(&mut self, p: Phase) {
        self.phase = p;
        self.phase_t = 0.0;
    }

    fn chirp(&self, notes: &[(f32, f32)]) {
        if let Some(a) = &self.audio {
            a.chirp(notes)
        }
    }
    fn thud(&self, k: f32) {
        if let Some(a) = &self.audio {
            a.thud(k)
        }
    }
    fn roar(&self, k: f32) {
        if let Some(a) = &self.audio {
            a.set_roar(k)
        }
    }
    fn tick_sound(&self) {
        if let Some(a) = &self.audio {
            a.tick()
        }
    }

    // MARK: - Step

    pub fn step(&mut self, dt: f32) {
        self.t += dt;
        if self.paused {
            self.brush_speed *= (-dt * 6.0).exp();
            self.v = 0.0;
            self.w = 0.0;
            if let Some(a) = &self.audio {
                a.set_motor(0.04, 0.0)
            }
            self.status = "Paused".into();
            return;
        }
        self.phase_t += dt;
        if !ALL_STILL.contains(&self.phase) {
            self.run_time += dt;
        }
        self.update_phase(dt);
        self.integrate_robot(dt);
        self.update_items(dt);
        self.update_particles(dt);
        self.heavy *= (-dt * 3.0).exp();
        self.bumper *= (-dt * 7.0).exp();
        self.shake *= (-dt * 8.0).exp();
        self.bag_glow *= (-dt * 2.0).exp();
        if self.draining {
            self.bag_fill = (self.bag_fill - dt / 1.4).max(0.0);
            self.bag_glow = 1.0;
            self.shake = self.shake.max(0.08);
            if self.bag_fill <= 0.0 {
                self.draining = false;
                self.roar(0.0);
                if self.discarded == Some(CleanMode::Delete) {
                    self.thud(0.7);
                    self.chirp(&[(392.0, 0.12), (262.0, 0.22)]);
                } else {
                    self.chirp(&[(659.0, 0.08), (523.0, 0.16)]);
                }
            }
        }
        self.led_pulse += dt;
        let suck = self.suction_on();
        self.brush_angle += self.brush_speed * dt;
        self.lidar_angle += self.lidar_speed * dt;
        self.brush_speed += ((if suck { 26.0 } else { 0.0 }) * (1.0 - self.heavy * 0.7) - self.brush_speed) * (dt * 3.0).min(1.0);
        let lidar_target = if matches!(self.phase, Phase::Dropping | Phase::Done | Phase::Tidied) {
            0.0
        } else {
            16.0
        };
        self.lidar_speed += (lidar_target - self.lidar_speed) * (dt * 2.0).min(1.0);
        let level = if suck {
            1.0
        } else if matches!(self.phase, Phase::Undocking | Phase::Scanning | Phase::Returning | Phase::Docking) {
            0.3
        } else {
            0.0
        };
        if let Some(a) = &self.audio {
            a.set_motor(if self.picked { level * 0.6 } else { level }, self.heavy);
        }
        self.battery = clampf(self.battery - (if suck { 0.0016 } else { 0.0 }) * dt, 0.0, 1.0);
        if matches!(self.phase, Phase::Emptying | Phase::Done) {
            self.battery = (self.battery + dt * 0.01).min(1.0);
        }
    }

    pub fn suction_on(&self) -> bool {
        matches!(self.phase, Phase::Cleaning | Phase::Hunting)
            || (self.phase == Phase::Returning && !self.finishing && self.remaining() > 0)
    }

    // MARK: - Phases

    fn update_phase(&mut self, dt: f32) {
        match self.phase {
            Phase::Dropping => {
                self.status = "Setting down".into();
                self.dock_drop = (self.phase_t / 0.42).min(1.0);
                if self.phase_t >= 0.42 && self.phase_t - dt < 0.42 {
                    self.land_dock();
                }
                if self.phase_t > 1.3 {
                    self.chirp(&[(659.0, 0.09), (880.0, 0.09), (1175.0, 0.16)]);
                    self.set_phase(Phase::Undocking);
                }
            }
            Phase::Undocking => {
                self.status = if self.was_emptying_mid_run {
                    "Back to work"
                } else {
                    "Leaving the dock"
                }
                .into();
                self.drive_raw(150.0 * self.speed_scale, 0.0, dt);
                if (self.pos - self.dock_pos).len() > self.r * 1.9 {
                    if self.was_emptying_mid_run || !self.first_stop {
                        self.was_emptying_mid_run = false;
                        self.begin_cleaning();
                    } else {
                        self.set_phase(Phase::Scanning);
                    }
                    self.first_stop = false;
                }
            }
            Phase::Scanning => {
                self.status = "Mapping your desktop".into();
                self.scan_active = (self.scan_active + dt * 3.0).min(1.0);
                let rate = 2.1;
                self.drive_raw(0.0, rate, dt);
                let prev = self.scan_sweep;
                self.scan_sweep += rate * dt;
                let pos = self.pos;
                let sweep = self.scan_sweep;
                let mut pings = 0;
                for it in self.items.iter_mut().filter(|it| !it.seen) {
                    let d = it.icon.pos - pos;
                    let mut a = d.y.atan2(d.x) + PI / 2.0;
                    while a < 0.0 {
                        a += 2.0 * PI;
                    }
                    if a <= sweep && a > prev - 0.001 {
                        it.seen = true;
                        it.ping = 1.0;
                        pings += 1;
                    }
                }
                self.tick_budget += 0.3 * pings as f32;
                if self.tick_budget > 1.0 {
                    self.tick_budget = 0.0;
                    self.tick_sound();
                }
                if self.scan_sweep > 2.0 * PI {
                    for it in self.items.iter_mut().filter(|it| !it.seen) {
                        it.seen = true;
                        it.ping = 1.0;
                    }
                    self.chirp(&[(880.0, 0.08), (1319.0, 0.14)]);
                    self.begin_cleaning();
                }
            }
            Phase::Cleaning => {
                self.scan_active = (self.scan_active - dt * 2.0).max(0.0);
                self.status = if self.heavy > 0.35 { "Big file. Straining…" } else { "Cleaning" }.into();
                self.follow_path(dt);
                if self.bin_count >= self.bin_capacity && self.remaining() > 0 {
                    self.go_dock(true);
                    return;
                }
                if self.path_i >= self.path.len() {
                    if self.remaining() == 0 {
                        self.go_dock(false);
                    } else {
                        self.set_phase(Phase::Hunting);
                        self.hunt_target = None;
                    }
                }
            }
            Phase::Hunting => {
                self.status = "Picking up stragglers".into();
                if self.bin_count >= self.bin_capacity && self.remaining() > 0 {
                    self.go_dock(true);
                    return;
                }
                let stale = match self.hunt_target {
                    None => true,
                    Some(h) => self.items[h].icon.gone || self.items[h].icon.ingesting,
                };
                if stale {
                    self.hunt_target = self.nearest_remaining();
                    self.hunt_t = 0.0;
                    match self.hunt_target {
                        Some(h) => {
                            self.path = vec![self.clamp_to_walk(self.items[h].icon.pos)];
                            self.path_i = 0;
                        }
                        None => {
                            self.go_dock(false);
                            return;
                        }
                    }
                }
                self.hunt_t += dt;
                if let Some(h) = self.hunt_target {
                    self.path = vec![self.clamp_to_walk(self.items[h].icon.pos)];
                    self.path_i = 0;
                    // Something wedged out of reach: reel it in from a distance rather than circle forever.
                    if self.hunt_t > 7.0 {
                        self.start_ingest(h, Part::Icon);
                    }
                }
                self.follow_path(dt);
            }
            Phase::Returning => {
                self.status = if self.finishing {
                    "Heading home"
                } else {
                    "Bin full, heading to the dock"
                }
                .into();
                self.led = [1.0, 0.68, 0.2];
                self.follow_path(dt);
                if self.path_i >= self.path.len() {
                    self.set_phase(Phase::Docking);
                    self.chirp(&[(740.0, 0.08), (587.0, 0.12)]);
                }
            }
            Phase::Docking => {
                self.status = "Reversing onto the dock".into();
                let out = self.dock_out.y.atan2(self.dock_out.x);
                let along = (self.pos - self.dock_pos).dot(self.dock_out);
                // Tail points at the dock while far out, straightens as it arrives.
                let to_dock = self.dock_pos - self.pos;
                let aim_tail = (-to_dock.y).atan2(-to_dock.x);
                let want = if along > self.r * 0.7 { aim_tail } else { out };
                let err = wrap_angle(want - self.heading);
                if !self.dock_aligned {
                    self.drive_raw(0.0, clampf(err * 3.0, -2.2, 2.2), dt);
                    if err.abs() < 0.06 {
                        self.dock_aligned = true;
                    }
                } else {
                    self.drive_raw(
                        -clampf(along * 1.5 + 34.0, 34.0, 135.0) * self.speed_scale,
                        clampf(err * 2.6, -0.9, 0.9),
                        dt,
                    );
                    // Last centimetres: the ramp's guide rails centre it.
                    if along < self.r * 0.5 {
                        let lateral = (self.pos - self.dock_pos).dot(self.dock_out.perp());
                        self.pos -= self.dock_out.perp() * (lateral * (dt * 5.0).min(1.0));
                    }
                    if along <= 0.5 {
                        self.pos = self.dock_pos;
                        self.heading = out;
                        self.v = 0.0;
                        self.w = 0.0;
                        self.dock_aligned = false;
                        self.shake = 0.35;
                        self.thud(0.35);
                        self.chirp(&[(523.0, 0.09), (659.0, 0.09), (784.0, 0.09), (1047.0, 0.2)]);
                        self.led = [0.35, 1.0, 0.5];
                        self.set_phase(Phase::Emptying);
                        self.prepare_emptying();
                    }
                }
            }
            Phase::Emptying => {
                self.status = "Self-emptying".into();
                let roar_on = self.phase_t > 0.7 && self.phase_t < self.empty_duration + 0.7;
                self.roar(if roar_on { 1.0 } else { 0.0 });
                if roar_on {
                    self.shake = self.shake.max(0.09);
                    self.bag_glow = 1.0;
                }
                if self.phase_t > 0.7 {
                    self.fly_emptying(dt);
                }
                if self.phase_t > self.empty_duration + 1.6 {
                    if self.finishing {
                        self.chirp(&[(784.0, 0.1), (988.0, 0.1), (1175.0, 0.1), (1568.0, 0.3)]);
                        self.set_phase(Phase::Done);
                        self.done_once = true;
                        if self.mode == CleanMode::Tidy {
                            self.start_tidy();
                        } else if self.skip_final_click {
                            self.discard(self.mode);
                        }
                    } else {
                        self.led = [0.2, 0.85, 1.0];
                        self.was_emptying_mid_run = true;
                        self.chirp(&[(659.0, 0.09), (880.0, 0.14)]);
                        self.set_phase(Phase::Undocking);
                    }
                }
            }
            Phase::Done => {
                self.status = if self.discarded.is_none() {
                    "All clean".into()
                } else {
                    self.done_status()
                };
            }
            Phase::Tidying => {
                self.status = "Sorting into columns".into();
                if self.phase_t > 3.8 {
                    self.set_phase(Phase::Tidied);
                }
            }
            Phase::Tidied => self.status = "Tidy-up preview".into(),
            Phase::PuttingBack => {
                self.status = "Putting everything back".into();
                if self.phase_t > 2.4 {
                    self.roar(0.0);
                }
                if self.phase_t > 3.9 {
                    self.set_phase(Phase::Leaving);
                    self.chirp(&[(1047.0, 0.08), (784.0, 0.08), (523.0, 0.14)]);
                }
            }
            Phase::Leaving => {
                self.status = "Everything's back".into();
                let k = clampf(self.phase_t / 0.5, 0.0, 1.0);
                self.dock_alpha = 1.0 - k;
                self.robot_alpha = 1.0 - k;
                if self.phase_t > 0.6 {
                    self.set_phase(Phase::Finished);
                }
            }
            Phase::Finished => {}
        }
    }

    fn land_dock(&mut self) {
        self.thud(1.0);
        self.shake = 1.0;
        // The air it pushes out shoves nearby icons away.
        let center = self.dock_pos + self.dock_out * (-self.r * 0.5);
        let reach = self.r * 3.4;
        for i in 0..self.items.len() {
            let d = self.items[i].icon.pos - center;
            let l = d.len();
            if l < reach {
                let k = 1.0 - l / reach;
                let spin = self.rand(-5.0, 5.0) * k;
                let it = &mut self.items[i];
                it.icon.vel += d.unit() * (520.0 * k * k) / it.mass;
                it.icon.ang_v += spin;
                it.icon.agit = it.icon.agit.max(k);
            }
        }
        for _ in 0..70 {
            let a = self.rand(0.0, std::f32::consts::TAU);
            let p = self.dock_pos + v2(a.cos() * self.r * 1.3, a.sin() * self.r * 1.0);
            let speed = self.rand(120.0, 420.0);
            let life = self.rand(0.3, 0.8);
            let size = self.rand(1.5, 4.0);
            self.spawn(p, v2(a.cos(), a.sin()) * speed, life, size, [1.0, 1.0, 1.0, 0.3], 0.0);
        }
    }

    fn begin_cleaning(&mut self) {
        self.led = [0.2, 0.85, 1.0];
        self.plan_lanes();
        self.set_phase(Phase::Cleaning);
    }

    pub fn go_dock(&mut self, mid: bool) {
        self.finishing = !mid;
        if !mid {
            self.hunt_target = None;
        }
        self.path = vec![self.dock_pos + self.dock_out * (self.r * 3.0)];
        self.path_i = 0;
        self.set_phase(Phase::Returning);
    }

    fn nearest_remaining(&self) -> Option<usize> {
        let mut best = None;
        let mut bd = f32::INFINITY;
        for it in &self.items {
            if it.on_floor() && !it.icon.ingesting && !it.grabbed {
                let d = (it.icon.pos - self.pos).len();
                if d < bd {
                    bd = d;
                    best = Some(it.index);
                }
            }
        }
        best
    }

    fn clamp_to_walk(&self, p: V2) -> V2 {
        let r = self.r;
        v2(
            clampf(p.x, self.wall_min.x + r + 2.0, self.wall_max.x - r - 2.0),
            clampf(p.y, self.wall_min.y + r + 2.0, self.wall_max.y - r - 2.0),
        )
    }

    /// Lawn-mower rows over where the mess actually is, starting from the nearest end.
    fn plan_lanes(&mut self) {
        let live: Vec<V2> = self.items.iter().filter(|it| it.on_floor()).map(|it| it.icon.pos).collect();
        self.path.clear();
        self.path_i = 0;
        if live.is_empty() {
            return;
        }
        let r = self.r;
        let step = r * 1.6;
        let min_y = live
            .iter()
            .map(|p| p.y)
            .fold(f32::INFINITY, f32::min)
            .max(self.wall_min.y + r + 2.0);
        let max_y = live
            .iter()
            .map(|p| p.y)
            .fold(f32::NEG_INFINITY, f32::max)
            .min(self.wall_max.y - r - 2.0);
        let mut lanes: Vec<(f32, f32, f32)> = Vec::new();
        let mut y = min_y;
        while y <= max_y + step * 0.5 {
            let yy = y.min(max_y);
            let band: Vec<f32> = live.iter().filter(|p| (p.y - yy).abs() < step * 0.62).map(|p| p.x).collect();
            if !band.is_empty() {
                let lo = band.iter().cloned().fold(f32::INFINITY, f32::min);
                let hi = band.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
                lanes.push((yy, lo - r * 0.5, hi + r * 0.5));
            }
            y += step;
        }
        let first_y = lanes.first().map(|l| l.0).unwrap_or(0.0);
        let last_y = lanes.last().map(|l| l.0).unwrap_or(0.0);
        if (first_y - self.pos.y).abs() > (last_y - self.pos.y).abs() {
            lanes.reverse();
        }
        let mut x = self.pos.x;
        for (ly, a, b) in lanes {
            let near = if (a - x).abs() < (b - x).abs() { a } else { b };
            let far = if near == a { b } else { a };
            for p in [v2(near, ly), v2(far, ly)] {
                let q = self.clamp_to_walk(p);
                if !self.inside_keep_out(q) {
                    self.path.push(q);
                }
            }
            x = far;
        }
        self.waypoint_t = 0.0;
    }

    fn inside_keep_out(&self, p: V2) -> bool {
        let d = p - self.dock_pos;
        let u = d.dot(self.dock_out);
        let s = d.dot(self.dock_out.perp()).abs();
        u < self.r * 2.0 && s < self.r * 2.3
    }

    /// Slides the robot along the dock's outline so it never drives over it.
    fn push_out_of_dock(&mut self) {
        if !self.inside_keep_out(self.pos) {
            return;
        }
        let d = self.pos - self.dock_pos;
        let u = d.dot(self.dock_out);
        let s = d.dot(self.dock_out.perp());
        let to_front = self.r * 2.0 - u;
        let to_side = self.r * 2.3 - s.abs();
        if to_front < to_side {
            self.pos += self.dock_out * to_front;
        } else {
            self.pos += self.dock_out.perp() * if s < 0.0 { -to_side } else { to_side };
        }
    }

    // MARK: - Motion

    fn follow_path(&mut self, dt: f32) {
        if self.path_i >= self.path.len() {
            self.drive_raw(0.0, 0.0, dt);
            return;
        }
        // Pointer in the way: bump, back off, swing round, like a real one meeting a foot.
        if let Some(m) = self.maneuver {
            self.drive_raw(
                if m.reverse > 0.0 { -110.0 } else { 0.0 },
                if m.reverse > 0.0 { 0.0 } else { m.dir * 2.6 },
                dt,
            );
            let mut n = m;
            if n.reverse > 0.0 {
                n.reverse -= dt;
            } else {
                n.turn -= dt;
            }
            self.maneuver = if n.turn > 0.0 { Some(n) } else { None };
            return;
        }
        if let Some(mp) = self.mouse {
            let d = mp - self.pos;
            let l = d.len();
            if l < self.r + 20.0 && d.dot(self.fwd()) > 0.0 && self.t - self.last_bump > 1.2 {
                self.last_bump = self.t;
                self.bumper = 1.0;
                self.thud(0.3);
                self.chirp(&[(494.0, 0.07), (392.0, 0.09)]);
                self.maneuver = Some(Maneuver {
                    reverse: 0.32,
                    turn: 0.45,
                    dir: if d.dot(self.side()) > 0.0 { -1.0 } else { 1.0 },
                });
                return;
            }
        }
        let mut target = self.path[self.path_i];
        self.waypoint_t += dt;
        let reach = if self.path_i == self.path.len() - 1 {
            self.r * 0.28
        } else {
            self.r * 0.45
        };
        if (target - self.pos).len() < reach || self.waypoint_t > 14.0 {
            self.path_i += 1;
            self.waypoint_t = 0.0;
            if self.path_i >= self.path.len() {
                return;
            }
            target = self.path[self.path_i];
        }
        // Carrot: blend towards the next waypoint when close, which rounds the corners.
        let to_t = target - self.pos;
        let mut aim = target;
        if self.path_i + 1 < self.path.len() && to_t.len() < self.r * 1.4 {
            let k = 1.0 - to_t.len() / (self.r * 1.4);
            aim = target + (self.path[self.path_i + 1] - target).unit() * (self.r * 0.9 * k);
        }
        let err = wrap_angle((aim.y - self.pos.y).atan2(aim.x - self.pos.x) - self.heading);
        let w_cmd = clampf(err * 4.2, -3.1, 3.1);
        let align = clampf(1.0 - err.abs() / 1.15, 0.0, 1.0);
        let mut v_cmd = 360.0 * align * align;
        if self.swallowing > 0 {
            v_cmd *= (1.0 - 0.22 * self.swallowing as f32).max(0.38);
        }
        if self.path_i == self.path.len() - 1 {
            v_cmd = v_cmd.min((to_t.len() * 2.2).max(70.0));
        }
        v_cmd *= 1.0 - 0.68 * clampf(self.heavy, 0.0, 1.0);
        self.drive_raw(v_cmd * self.speed_scale, w_cmd, dt);
    }

    fn drive_raw(&mut self, v_cmd: f32, w_cmd: f32, dt: f32) {
        let a = 720.0 * self.speed_scale;
        self.v += clampf(v_cmd - self.v, -a * dt, a * dt);
        let aw = 12.0;
        self.w += clampf(w_cmd - self.w, -aw * dt, aw * dt);
    }

    fn integrate_robot(&mut self, dt: f32) {
        if self.picked {
            self.v = 0.0;
            self.w = 0.0;
            return;
        }
        self.heading = wrap_angle(self.heading + self.w * dt);
        self.pos += self.fwd() * (self.v * dt);
        self.distance += (self.v * dt).abs();
        // Walls: bumper compresses, a small knock.
        let walled = self.clamp_to_walk(self.pos);
        if matches!(self.phase, Phase::Cleaning | Phase::Hunting | Phase::Returning) {
            if (walled - self.pos).len() > 0.3 {
                if self.t - self.last_bump > 0.9 && self.v.abs() > 90.0 {
                    self.last_bump = self.t;
                    self.bumper = 0.8;
                    self.thud(0.16);
                    self.v *= 0.4;
                }
                self.pos = walled;
            }
            self.push_out_of_dock();
        }
        if self.trail.last().is_none_or(|l| (self.pos - *l).len() > 26.0) {
            self.trail.push(self.pos);
            if self.trail.len() > 1600 {
                self.trail.drain(0..200);
            }
        }
    }

    // MARK: - Items

    fn start_ingest(&mut self, i: usize, part: Part) {
        {
            let it = &mut self.items[i];
            if it.body(part).ingesting || it.protected {
                return;
            }
            let b = it.body(part);
            b.ingesting = true;
            b.pull = 0.001;
        }
        if part == Part::Icon {
            if self.items[i].label_attached {
                self.detach_label(i);
            }
            let mass = self.items[i].mass;
            if let Some(a) = &self.audio {
                a.ingest(mass)
            }
            if mass > 3.4 {
                self.clog_events += 1;
            }
            let c = self.items[i].color;
            let ipos = self.items[i].icon.pos;
            let intake = self.intake();
            for _ in 0..(6 + (mass * 4.0) as usize) {
                let dir = (intake - ipos).unit().rotated(self.rand(-1.2, 1.2));
                let p = ipos + v2(self.rand(-24.0, 24.0), self.rand(-24.0, 24.0));
                let vel = dir * self.rand(80.0, 300.0);
                let life = self.rand(0.2, 0.5);
                let size = self.rand(2.0, 5.0);
                self.spawn(p, vel, life, size, [c[0], c[1], c[2], 0.95], 1.0);
            }
        }
    }

    fn detach_label(&mut self, i: usize) {
        let spin = self.rand(-5.0, 5.0);
        let off = self.label_offset;
        let it = &mut self.items[i];
        it.label_attached = false;
        it.label.pos = it.icon.pos + v2(0.0, off).rotated(it.icon.ang);
        it.label.vel = it.icon.vel;
        it.label.ang = it.icon.ang;
        it.label.ang_v = spin;
    }

    /// Pushes one body around by suction, brushes and the robot's shell. True: it reached the intake.
    fn apply_field(&self, b: &mut Body, mass: f32, on: bool, dt: f32) -> bool {
        let r = self.r;
        let fwd = self.fwd();
        let rel = b.pos - self.pos;
        let f = rel.dot(fwd);
        let s = rel.dot(self.side());
        let intake = self.intake();
        let to_intake = intake - b.pos;
        let d = to_intake.len();
        if on {
            // Suction: only reaches forward, and falls off fast.
            let reach = r * 2.5;
            if d < reach {
                let k = 1.0 - d / reach;
                let front = smooth(-r * 0.3, r * 0.5, f);
                let accel = 3300.0 * k * k * (0.2 + 0.8 * front) / mass;
                b.vel += to_intake.unit() * accel * dt;
                b.agit = b.agit.max(k * front * 1.15);
            }
            // Side brushes whirl things across the front of the robot and inwards.
            let (l, rr) = self.brush_centers();
            for (c, sign) in [(l, -1.0f32), (rr, 1.0f32)] {
                let e = b.pos - c;
                let el = e.len();
                let br = r * 0.62;
                if el < br {
                    let k = 1.0 - el / br;
                    let tangent = e.unit().perp() * sign;
                    b.vel += (tangent * 1300.0 + (intake - b.pos).unit() * 800.0) * k * dt / mass;
                    b.ang_v += sign * 14.0 * k * dt / mass * 6.0;
                    b.agit = b.agit.max(0.5 + k * 0.5);
                }
            }
        }
        // Robot body: shoves what it doesn't swallow.
        if !self.picked {
            let l = rel.len();
            let keep = r + 16.0;
            if on && f > r * 0.1 && s.abs() < r * 0.98 && l < r + 44.0 {
                return true;
            }
            if l < keep {
                let n = rel.unit();
                b.pos = self.pos + n * keep;
                let vr = (fwd * self.v).dot(n);
                if vr > 0.0 {
                    b.vel += n * vr * 1.1;
                }
                b.ang_v += n.perp().dot(fwd) * self.v * 0.012;
                b.agit = b.agit.max(0.5);
            }
        }
        false
    }

    fn update_items(&mut self, dt: f32) {
        let on = self.suction_on();
        let mut awake: Vec<usize> = Vec::new();
        self.swallowing = self.items.iter().filter(|it| it.icon.ingesting).count();
        for i in 0..self.items.len() {
            {
                let it = &mut self.items[i];
                it.ping = (it.ping - dt * 1.3).max(0.0);
                it.land = (it.land - dt * 4.0).max(0.0);
            }
            if self.items[i].flight != Flight::None {
                self.update_flight(i, dt);
                continue;
            }
            if self.items[i].in_bin || self.items[i].in_dock {
                continue;
            }
            if self.items[i].protected {
                // Not for collecting: can be nudged by the robot, but always settles back on its spot.
                let mut b = self.items[i].icon;
                let mass = self.items[i].mass;
                self.apply_field(&mut b, mass, false, dt);
                b.vel += (self.items[i].home - b.pos) * 26.0 * dt;
                integrate(&mut b, dt, 7.0);
                self.items[i].icon = b;
                continue;
            }
            // ICON
            if !self.items[i].icon.gone {
                if self.items[i].grabbed {
                    let b = &mut self.items[i].icon;
                    b.agit = b.agit.max(0.25);
                } else if self.items[i].icon.ingesting {
                    let dur = self.items[i].ingest_time;
                    self.advance_ingest(i, Part::Icon, dur, dt);
                    let mass = self.items[i].mass;
                    self.heavy = self.heavy.max(clampf((mass - 1.8) / 3.2, 0.0, 1.0));
                    if mass > 3.0 {
                        self.shake = self.shake.max(0.28 * mass / 6.0);
                    }
                    if self.items[i].icon.gone {
                        let bytes = self.items[i].entry.bytes;
                        self.items[i].in_bin = true;
                        self.bin_count += 1;
                        self.bin_bytes += bytes;
                        self.collected += 1;
                        self.collected_bytes += bytes;
                        if mass > 3.0 {
                            self.chirp(&[(392.0, 0.05)]);
                        }
                    }
                } else {
                    let mut b = self.items[i].icon;
                    let mass = self.items[i].mass;
                    let hit = self.apply_field(&mut b, mass, on, dt);
                    self.items[i].icon = b;
                    if hit {
                        self.start_ingest(i, Part::Icon);
                    }
                    let mut b = self.items[i].icon;
                    integrate(&mut b, dt, 5.5);
                    self.push_out_of_dock_item(&mut b);
                    self.clamp_item(&mut b, 26.0);
                    self.items[i].icon = b;
                }
                if self.items[i].icon.agit > 0.02 {
                    awake.push(i);
                }
            }
            // LABEL
            if self.items[i].label_attached {
                let it = &self.items[i];
                if it.icon.agit > 0.62 + 0.25 * (it.icon.seed * 13.0).sin() {
                    self.detach_label(i);
                }
            }
            if !self.items[i].label_attached && !self.items[i].label.gone {
                if self.items[i].label.ingesting {
                    self.advance_ingest(i, Part::Label, 0.3, dt);
                } else {
                    let mut b = self.items[i].label;
                    let hit = self.apply_field(&mut b, 0.32, on, dt);
                    self.items[i].label = b;
                    if hit {
                        self.start_ingest(i, Part::Label);
                    }
                    if self.items[i].icon.gone {
                        // Its icon is gone: a label left behind flutters a bit, then gets taken.
                        self.items[i].label_lost += dt;
                        let near = (self.intake() - self.items[i].label.pos).len() < self.r * 2.6;
                        if self.items[i].label_lost > 0.8 || near {
                            self.start_ingest(i, Part::Label);
                        }
                    }
                    let mut b = self.items[i].label;
                    integrate(&mut b, dt, 3.6);
                    let t = self.t;
                    b.vel += v2((t * 7.0 + b.seed).sin(), (t * 5.3 + b.seed * 2.0).cos()) * 60.0 * b.agit * dt;
                    self.clamp_item(&mut b, 30.0);
                    self.items[i].label = b;
                }
            }
        }
        // Stirred-up icons shoulder each other aside; calm ones keep their exact spot.
        if awake.len() > 1 && awake.len() < 120 {
            for ii in 0..awake.len() {
                for jj in (ii + 1)..awake.len() {
                    let (ia, ib) = (awake[ii], awake[jj]);
                    let (a, b) = (&self.items[ia], &self.items[ib]);
                    if a.icon.ingesting || b.icon.ingesting || a.grabbed || b.grabbed {
                        continue;
                    }
                    let d = b.icon.pos - a.icon.pos;
                    let l = d.len();
                    if l < 54.0 && l > 0.01 {
                        let p = d.unit() * ((54.0 - l) * 7.0 * dt);
                        let (ma, mb) = (a.mass, b.mass);
                        self.items[ia].icon.pos -= p / ma;
                        self.items[ib].icon.pos += p / mb;
                    }
                }
            }
        }
    }

    fn advance_ingest(&mut self, i: usize, part: Part, duration: f32, dt: f32) {
        let intake = self.intake();
        let b = self.items[i].body(part);
        b.pull = (b.pull + dt / duration).min(1.0);
        let k = 1.0 - (-dt * (2.5 + 9.0 * b.pull * b.pull)).exp();
        b.pos += (intake - b.pos) * k;
        b.agit = 1.0;
        b.ang += b.ang_v * dt;
        if b.pull >= 1.0 {
            b.gone = true;
            b.ingesting = false;
        }
    }

    fn clamp_item(&self, b: &mut Body, pad: f32) {
        if b.pos.x < pad {
            b.pos.x = pad;
            b.vel.x = b.vel.x.abs() * 0.4;
        }
        if b.pos.x > self.size.x - pad {
            b.pos.x = self.size.x - pad;
            b.vel.x = -b.vel.x.abs() * 0.4;
        }
        if b.pos.y < self.wall_min.y + pad {
            b.pos.y = self.wall_min.y + pad;
            b.vel.y = b.vel.y.abs() * 0.4;
        }
        if b.pos.y > self.wall_max.y - pad {
            b.pos.y = self.wall_max.y - pad;
            b.vel.y = -b.vel.y.abs() * 0.4;
        }
    }

    fn push_out_of_dock_item(&self, b: &mut Body) {
        // Keep icons off the tower so nothing gets lost behind it.
        let d = b.pos - self.dock_pos;
        let u = d.dot(self.dock_out);
        let s = d.dot(self.dock_out.perp());
        let r = self.r;
        if u < r && u > -r * 2.3 && s.abs() < r * 1.45 {
            b.pos += self.dock_out * (r - u);
            b.vel += self.dock_out * 60.0;
        }
    }

    // MARK: - Emptying and putting back

    pub fn bag_pos(&self) -> V2 {
        self.dock_pos - self.dock_out * (self.r * 1.5)
    }

    fn prepare_emptying(&mut self) {
        self.empty_queue = self.items.iter().filter(|it| it.in_bin).map(|it| it.index).collect();
        let n = self.empty_queue.len() as f32;
        self.empty_duration = clampf(n * 0.09, 2.2, 5.0);
        self.empty_rate = n / (self.empty_duration * 0.9);
        self.empty_acc = 0.0;
    }

    fn fly_emptying(&mut self, dt: f32) {
        if self.empty_queue.is_empty() {
            return;
        }
        self.empty_acc += dt * self.empty_rate;
        while self.empty_acc >= 1.0 {
            let Some(i) = self.empty_queue.pop() else { break };
            self.empty_acc -= 1.0;
            let r = self.r;
            let from = self.pos + v2(self.rand(-18.0, 18.0), self.rand(-18.0, 18.0));
            let to = self.bag_pos() + v2(self.rand(-r * 0.5, r * 0.5), self.rand(-r * 0.16, r * 0.16));
            let spin = self.rand(-9.0, 9.0);
            let ang = self.rand(-1.0, 1.0);
            let it = &mut self.items[i];
            it.in_bin = false;
            it.flight = Flight::ToBag;
            it.flight_from = from;
            it.flight_to = to;
            it.flight_t = 0.0;
            it.flight_delay = 0.0;
            it.flight_dur = 0.42;
            it.flight_spin = spin;
            it.flight_scale = 0.34;
            it.icon.gone = false;
            it.icon.pos = from;
            it.icon.pull = 0.0;
            it.icon.agit = 0.0;
            it.icon.ang = ang;
            it.icon.ingesting = false;
        }
    }

    fn update_flight(&mut self, i: usize, dt: f32) {
        let n_items = self.items.len().max(1) as f32;
        let it = &mut self.items[i];
        if it.flight_delay > 0.0 {
            it.flight_delay -= dt;
            return;
        }
        it.flight_t = (it.flight_t + dt / it.flight_dur).min(1.0);
        let k = it.flight_t;
        let e = if it.flight == Flight::ToBag {
            k * k
        } else {
            1.0 - (1.0 - k).powi(3)
        };
        let span = it.flight_to - it.flight_from;
        let mut p = it.flight_from + span * e;
        // Airborne arc, seen from above as a slight sideways bow.
        let bow =
            span.perp().unit() * ((k * PI).sin() * (span.len() * 0.12).min(90.0) * if it.index.is_multiple_of(2) { 1.0 } else { -1.0 });
        if it.flight != Flight::ToBag {
            p += bow;
        }
        it.icon.pos = p;
        let mut tick = 0.0;
        let mut landed_in_bag = None;
        match it.flight {
            Flight::ToBag => {
                it.flight_scale = 0.34 * (1.0 - k * 0.65);
                it.icon.ang += it.flight_spin * dt;
                if k >= 1.0 {
                    it.flight = Flight::None;
                    it.in_dock = true;
                    it.icon.gone = true;
                    landed_in_bag = Some(it.entry.bytes);
                    tick = 0.45;
                }
            }
            Flight::ToHome | Flight::ToTidy => {
                it.flight_scale = 0.18 + (1.0 - 0.18) * smooth(0.0, 0.8, k);
                it.icon.ang = it.flight_spin * (1.0 - e);
                if k >= 1.0 {
                    it.flight = Flight::None;
                    it.in_dock = false;
                    it.in_bin = false;
                    it.icon.pos = it.flight_to;
                    it.icon.ang = 0.0;
                    it.icon.vel = V2::ZERO;
                    it.icon.gone = false;
                    it.icon.agit = 0.0;
                    it.icon.ang_v = 0.0;
                    it.label_attached = true;
                    it.label.gone = false;
                    it.label.ingesting = false;
                    it.label.pull = 0.0;
                    it.label_lost = 0.0;
                    it.flight_scale = 1.0;
                    it.land = 1.0;
                    it.rest = it.flight_to;
                    tick = 0.35;
                }
            }
            Flight::None => {}
        }
        if let Some(bytes) = landed_in_bag {
            self.bin_count -= 1;
            self.bin_bytes -= bytes;
            self.bag_fill = clampf(self.bag_fill + 1.0 / n_items, 0.0, 1.0);
        }
        if tick > 0.0 {
            self.tick_budget += tick;
            if self.tick_budget > 1.0 {
                self.tick_budget = 0.0;
                self.tick_sound();
            }
        }
    }

    /// Fans the same sprites out into columns by kind, from the top-left like Explorer's auto-arrange.
    pub fn start_tidy(&mut self) {
        self.set_phase(Phase::Tidying);
        let mut grouped: Vec<usize> = Vec::new();
        for k in Kind::ALL {
            grouped.extend(
                self.items
                    .iter()
                    .filter(|it| it.entry.kind == k && !it.protected)
                    .map(|it| it.index),
            );
        }
        let (origin, grid) = self.tidy_grid;
        // Rows that fit with their label above the bottom edge.
        let rows = (((self.wall_max.y - origin.y - 69.0) / grid.y).floor() as usize + 1).max(1);
        // Cells held by icons that stay put (This PC, the Recycle Bin) are skipped.
        let cell_of = |p: V2| {
            (
                ((p.x - origin.x) / grid.x).round() as i64,
                ((p.y - origin.y) / grid.y).round() as i64,
            )
        };
        let taken: std::collections::HashSet<(i64, i64)> = self.items.iter().filter(|it| it.protected).map(|it| cell_of(it.home)).collect();
        let cols = (grouped.len() + taken.len()).div_ceil(rows);
        // A very full desktop tightens the columns so that everything stays on screen.
        let pitch = grid.x.min((self.size.x - 2.0 * origin.x) / (cols.max(2) - 1) as f32);
        let mut cells = (0..)
            .map(|n: usize| ((n / rows) as i64, (n % rows) as i64))
            .filter(|c| !taken.contains(c));
        let slots: Vec<(usize, V2)> = grouped
            .iter()
            .map(|&i| {
                let (col, row) = cells.next().unwrap();
                (i, v2(origin.x + col as f32 * pitch, origin.y + row as f32 * grid.y))
            })
            .collect();
        let bag = self.bag_pos();
        self.launch(&slots, |_| bag, Flight::ToTidy, 3.0);
        self.roar(0.0);
    }

    pub fn done_status(&self) -> String {
        let tail = if self.real_run { "" } else { " (preview)" };
        let what = if self.discarded == Some(CleanMode::Delete) {
            "Deleted"
        } else {
            "Moved to the Recycle Bin"
        };
        format!("{what}{tail}")
    }

    /// The real action finished: anything left alone flies home, then the dock leaves.
    pub fn finish_after_action(&mut self, returning: &[usize]) {
        self.draining = false;
        self.bag_fill = 0.0;
        self.roar(0.0);
        if returning.is_empty() {
            self.set_phase(Phase::Leaving);
            return;
        }
        let slots: Vec<(usize, V2)> = returning.iter().map(|&i| (i, self.items[i].home)).collect();
        let bag = self.bag_pos();
        self.launch(&slots, |_| bag, Flight::ToHome, 1.4);
        self.set_phase(Phase::PuttingBack);
    }

    /// Drains the bag for the chosen outcome. Only a picture of it: no file is touched.
    pub fn discard(&mut self, choice: CleanMode) {
        if self.phase != Phase::Done || self.discarded.is_some() || choice == CleanMode::Tidy {
            return;
        }
        self.discarded = Some(choice);
        self.draining = true;
        self.roar(0.7);
        self.status = self.done_status();
    }

    pub fn put_back(&mut self) {
        if !matches!(self.phase, Phase::Done | Phase::Tidied | Phase::Tidying) {
            return;
        }
        self.draining = false;
        self.set_phase(Phase::PuttingBack);
        self.led = [0.5, 0.75, 1.0];
        let slots: Vec<(usize, V2)> = self.items.iter().map(|it| (it.index, it.home)).collect();
        let bag = self.bag_pos();
        let froms: Vec<V2> = self.items.iter().map(|it| if it.in_dock { bag } else { it.icon.pos }).collect();
        self.launch(&slots, |i| froms[i], Flight::ToHome, 2.9);
        self.roar(0.55);
        self.bag_fill = 0.0;
    }

    fn launch(&mut self, slots: &[(usize, V2)], from: impl Fn(usize) -> V2, flight: Flight, spread: f32) {
        let n = slots.len().max(1) as f32;
        for (k, &(i, to)) in slots.iter().enumerate() {
            let dur = 0.75 + self.rand(0.0, 0.25);
            let spin = self.rand(-2.5, 2.5);
            let f = from(i);
            let it = &mut self.items[i];
            it.flight_from = f;
            it.flight = flight;
            it.flight_to = to;
            it.icon.gone = false;
            it.icon.ingesting = false;
            it.icon.pos = f;
            it.icon.pull = 0.0;
            it.icon.agit = 0.0;
            it.flight_t = 0.0;
            it.flight_delay = spread * 0.72 * k as f32 / n;
            it.flight_dur = dur;
            it.flight_spin = spin;
            it.flight_scale = 0.18;
            it.label_attached = true;
            it.label.gone = false;
            it.label.pull = 0.0;
            it.label.ingesting = false;
        }
    }

    // MARK: - Pointer

    pub fn hit_robot(&self, p: V2) -> bool {
        (p - self.pos).len() < self.r
            && !matches!(
                self.phase,
                Phase::Docking | Phase::Emptying | Phase::Dropping | Phase::PuttingBack | Phase::Leaving
            )
    }

    pub fn hit_item(&self, p: V2) -> Option<usize> {
        let mut best = None;
        let mut bd = 40.0;
        for it in self.items.iter().filter(|it| it.on_floor()) {
            let d = (it.icon.pos - p).len();
            if d < bd {
                bd = d;
                best = Some(it.index);
            }
        }
        best
    }

    pub fn pick_up(&mut self) {
        self.picked = true;
        self.chirp(&[(988.0, 0.1), (784.0, 0.1), (988.0, 0.1), (784.0, 0.16)]);
        self.status = "Put me down!".into();
    }
    pub fn drag_robot_to(&mut self, p: V2) {
        self.pos = self.clamp_to_walk(p);
    }
    pub fn drop_robot(&mut self) {
        self.picked = false;
        self.thud(0.55);
        self.shake = 0.6;
        self.push_out_of_dock();
        if self.phase == Phase::Cleaning {
            self.plan_lanes();
            self.phase_t = 0.0;
        }
    }

    // MARK: - Particles

    fn spawn(&mut self, p: V2, vel: V2, life: f32, size: f32, color: [f32; 4], chip: f32) {
        if self.particles.len() > 2300 {
            self.particles.drain(0..100);
        }
        let ang = self.rand(0.0, std::f32::consts::TAU);
        self.particles.push(Particle {
            pos: p,
            vel,
            life,
            max_life: life,
            size,
            color,
            chip,
            ang,
        });
    }

    fn update_particles(&mut self, dt: f32) {
        let on = self.suction_on();
        // Air the robot is drawing in, visible as a few fast specks.
        if on && !self.picked {
            let rate = 44.0 * dt;
            let mut acc = rate + self.rand(0.0, 1.0);
            while acc >= 1.0 {
                acc -= 1.0;
                let a = self.rand(-1.25, 1.25);
                let dir = self.fwd().rotated(a);
                let p = self.pos + dir * (self.r * self.rand(1.1, 1.95));
                let vel = -dir * self.rand(60.0, 140.0);
                let life = self.rand(0.25, 0.5);
                let size = self.rand(0.8, 2.0);
                self.spawn(p, vel, life, size, [1.0, 1.0, 1.0, 0.34], 0.0);
            }
        }
        let intake = self.intake();
        let r = self.r;
        let mut i = 0;
        while i < self.particles.len() {
            let q = &mut self.particles[i];
            q.life -= dt;
            if q.life <= 0.0 {
                self.particles.swap_remove(i);
                continue;
            }
            if on {
                let d = intake - q.pos;
                let l = d.len();
                if l < r * 3.0 {
                    q.vel += d.unit() * (2800.0 * (1.0 - l / (r * 3.0))) * dt;
                }
                if l < r * 0.5 {
                    q.life = 0.0;
                }
            }
            q.vel *= (-dt * 2.4).exp();
            q.pos += q.vel * dt;
            q.ang += dt * 9.0 * q.chip;
            i += 1;
        }
    }
}

fn integrate(b: &mut Body, dt: f32, damping: f32) {
    b.pos += b.vel * dt;
    b.vel *= (-dt * damping).exp();
    b.ang += b.ang_v * dt;
    b.ang_v *= (-dt * 3.2).exp();
    // Paper settles flat again, keeping any new position.
    b.ang += (0.0 - b.ang) * (1.0 - (-dt * 0.6 * (1.0 - b.agit)).exp());
    b.agit = (b.agit - dt * 1.7).max(0.0);
}
