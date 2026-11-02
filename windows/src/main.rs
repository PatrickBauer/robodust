#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod audio;
mod entries;
mod math;
mod offline;
mod platform;
mod render;
mod sim;
mod sprites;
mod ui;

static DEBUG: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// With --debug: appends a line to debug.log next to the settings (there's no console on Windows).
pub fn debug_log(text: &str) {
    if !DEBUG.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    use std::io::Write;
    let dir = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("RoboDust");
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("debug.log")) {
        let _ = writeln!(f, "{text}");
    }
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    DEBUG.store(args.iter().any(|a| a == "--debug"), std::sync::atomic::Ordering::Relaxed);
    if args.iter().any(|a| a == "--dump") {
        let mut o = offline::Options::default();
        if let Some(d) = arg_value(&args, "--dump") {
            o.dump_times = d.split(',').filter_map(|s| s.parse().ok()).collect();
        }
        if let Some(d) = arg_value(&args, "--out") {
            o.dump_dir = d;
        }
        if let Some(m) = arg_value(&args, "--mode")
            .and_then(|m| m.parse().ok())
            .and_then(sim::CleanMode::from_index)
        {
            o.mode = m;
        }
        if let Some(s) = arg_value(&args, "--seconds").and_then(|s| s.parse().ok()) {
            o.max_seconds = s;
        }
        o.skip = args.iter().any(|a| a == "--skip");
        offline::run(o);
        return;
    }
    let opts = app::Options {
        auto_start: args.iter().any(|a| a == "--auto"),
        // Dev only: a throwaway folder stands in for the desktop, and settings aren't saved.
        test_root: arg_value(&args, "--test-root").map(std::path::PathBuf::from),
        test_mode: arg_value(&args, "--test-mode")
            .and_then(|m| m.parse().ok())
            .and_then(sim::CleanMode::from_index)
            .filter(|m| m.offered()),
    };
    let event_loop = winit::event_loop::EventLoop::new().expect("event loop");
    let mut app = app::App::new(opts);
    event_loop.run_app(&mut app).expect("run");
}
