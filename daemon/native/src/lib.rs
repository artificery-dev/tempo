//! tempod - the Tempo device and service daemon.
//!
//! Two jobs, two threads:
//!
//! - **metrics**: sample the battery and the backlight from sysfs every
//!   `--interval` seconds into a SQLite store (grown from the bring-up
//!   `y2-stats` daemon, same schema).
//! - **control**: a unix-socket request/reply surface the frontend drives. One
//!   JSON line in, one JSON line out, per connection. The privileged operation
//!   today is `drm-handoff`: the frontend passes its DRM fd over the socket and
//!   tempod takes DRM master on it, retiring the plymouth splash in the process
//!   - the one thing an unprivileged flutter-pi cannot do for itself. The other
//!     is `screen`: the panel backlight, off and on with a ramp, for the power
//!     button's single tap.
//!
//! No async runtime, no framework: libc, rusqlite, serde. The protocol and
//! the operational contract are documented in docs/app/daemon.md.

use std::{env, io::Write, process::ExitCode, sync::Arc, thread};

/// Log one line to stderr (journald under systemd) as `<section>: <message>`.
macro_rules! log {
    ($section:expr, $($arg:tt)*) => {
        eprintln!("{}: {}", $section, format_args!($($arg)*))
    };
}

mod activation;
mod bridge;
mod clock;
mod control;
mod fdpass;
mod first_run;
mod handoff;
mod haptic;
mod metrics;
mod output;
mod power;
mod protocol;
mod radio;
mod screen;
mod settings;
mod sound;
mod timezone;
mod volume;

pub fn run_legacy() -> ExitCode {
    let settings = match settings::parse(env::args().skip(1), |k| env::var(k).ok()) {
        Ok(settings::Cli::Run(s)) => s,
        Ok(settings::Cli::Exit(text)) => {
            // Not println!: `tempod --help | head` must not panic on EPIPE.
            let _ = writeln!(std::io::stdout(), "{text}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("tempod: {e}");
            return ExitCode::from(2);
        }
    };
    log!("main", "tempod {} starting", settings::VERSION);

    // pipewire-alsa (the sounds' way out) finds the player user's sound
    // server through XDG_RUNTIME_DIR, which a system service is not given.
    // Still single-threaded here, so setting it is sound.
    if env::var_os("XDG_RUNTIME_DIR").is_none() {
        // SAFETY: no other thread exists yet.
        unsafe { env::set_var("XDG_RUNTIME_DIR", volume::Volume::runtime_dir()) };
    }

    // The listener comes first, and before any thread exists: taking the
    // socket systemd passed scrubs LISTEN_* from the environment, which is
    // only safe while the process is single-threaded.
    let listener = match control::listener(&settings.socket) {
        Ok(l) => l,
        Err(e) => {
            log!(
                "control",
                "cannot listen on {}: {e}",
                settings.socket.display()
            );
            return ExitCode::FAILURE;
        }
    };

    let sysfs = metrics::Sysfs::discover(|k| env::var(k).ok());
    log!(
        "metrics",
        "battery: {}, backlight: {}",
        sysfs
            .battery
            .as_deref()
            .map(|p| p.display().to_string())
            .unwrap_or("none".into()),
        sysfs
            .backlight
            .as_deref()
            .map(|p| p.display().to_string())
            .unwrap_or("none".into()),
    );
    let state = Arc::new(control::State::new(sysfs.clone()));

    if settings.sampler {
        let sampler = metrics::Sampler {
            db: settings.db.clone(),
            interval: settings.interval,
            retention_days: settings.retention_days,
        };
        let latest = Arc::clone(&state.latest);
        let spawned = thread::Builder::new()
            .name("metrics".into())
            .spawn(move || metrics::run(sampler, sysfs, latest));
        if let Err(e) = spawned {
            log!("metrics", "cannot start the sampler thread: {e}");
            return ExitCode::FAILURE;
        }
    } else {
        log!("metrics", "sampler disabled (--no-sampler)");
    }

    control::serve(listener, state)
}
