//! Privileged, graceful power requests. Never bypass systemd's shutdown
//! sequence.
use std::{
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Restart,
    Shutdown,
}

impl Action {
    fn argument(self) -> &'static str {
        match self {
            Self::Restart => "reboot",
            Self::Shutdown => "poweroff",
        }
    }
}

pub fn request(action: Action) -> Result<(), String> {
    let mut child = Command::new("/usr/bin/systemctl")
        .args(["--no-ask-password", "--no-block", action.argument()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Cannot request power action: {e}"))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return if status.success() {
                    Ok(())
                } else {
                    Err(format!("systemctl {} failed ({status})", action.argument()))
                };
            }
            Ok(None) if start.elapsed() < Duration::from_secs(5) => {
                thread::sleep(Duration::from_millis(20))
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match result {
                    Err(e) => e.to_string(),
                    _ => "Power request timed out".into(),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Op, parse_request};
    #[test]
    fn power_requests_have_fixed_commands() {
        assert_eq!(
            parse_request(br#"{"op":"reboot"}"#),
            Ok(Op::Power(Action::Restart))
        );
        assert_eq!(
            parse_request(br#"{"op":"poweroff"}"#),
            Ok(Op::Power(Action::Shutdown))
        );
        assert_eq!(Action::Restart.argument(), "reboot");
        assert_eq!(Action::Shutdown.argument(), "poweroff");
    }
}
