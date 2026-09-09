//! tempo-kms: the KMS plumbing shared by the Tempo device tools.
//!
//! `tempo-show` (a still image on the panel) and `tempo-cube` (the GPU
//! benchmark) start the same way: open the DRM card, find the connected
//! panel, pick its mode, and find a CRTC to drive it. That is what lives
//! here, and nothing more - the tools keep their own buffers and present
//! loops. Anything that wants to own the panel (a VT/screen switcher, a
//! recovery console) starts from [`Card::find_target`] too.
//!
//! DRM is spoken with the pure-Rust `drm` crate (ioctls, no libdrm at link
//! time), re-exported as [`drm`] so every user shares one version of its
//! types.

use std::{
    fmt,
    fs::{File, OpenOptions},
    io,
    os::fd::{AsFd, BorrowedFd},
    path::Path,
};

pub use drm;
use drm::{
    Device as DrmDevice,
    control::{Device as ControlDevice, Mode, ModeTypeFlags, connector, crtc},
};

/// The Y2's one DRM device (mtk-drm, with lima as the render node).
pub const DEFAULT_CARD: &str = "/dev/dri/card0";

/// A DRM device handle: a `File` that also speaks the `drm` traits.
#[derive(Debug)]
pub struct Card(File);

impl AsFd for Card {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl DrmDevice for Card {}
impl ControlDevice for Card {}

impl Card {
    /// Open a DRM card node read-write.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Card> {
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map(Card)
    }

    /// Open [`DEFAULT_CARD`].
    pub fn open_default() -> io::Result<Card> {
        Card::open(DEFAULT_CARD)
    }

    /// Find the first connected connector, its preferred mode, and a CRTC to
    /// drive it.
    ///
    /// The CRTC is the one behind the connector's current encoder when
    /// something is already attached (the usual case: the splash or the UI
    /// was just on it), else the first CRTC the device exposes.
    pub fn find_target(&self) -> Result<Target, Error> {
        let res = self.resource_handles()?;

        let conn = res
            .connectors()
            .iter()
            .map(|h| self.get_connector(*h, false))
            .collect::<io::Result<Vec<_>>>()?
            .into_iter()
            .find(|c| c.state() == connector::State::Connected)
            .ok_or(Error::NoConnector)?;

        let modes = conn.modes();
        let mode = modes
            .iter()
            .find(|m| m.mode_type().contains(ModeTypeFlags::PREFERRED))
            .or_else(|| modes.first())
            .copied()
            .ok_or(Error::NoMode)?;

        let crtc = match conn.current_encoder() {
            Some(enc) => self.get_encoder(enc)?.crtc(),
            None => None,
        }
        .or_else(|| res.crtcs().first().copied())
        .ok_or(Error::NoCrtc)?;

        Ok(Target {
            connector: conn.handle(),
            interface: conn.interface(),
            crtc,
            mode,
        })
    }
}

/// The pieces of KMS state needed to drive one panel.
#[derive(Debug, Clone, Copy)]
pub struct Target {
    pub connector: connector::Handle,
    pub interface: connector::Interface,
    pub crtc: crtc::Handle,
    pub mode: Mode,
}

impl Target {
    /// The mode's active area, in pixels.
    pub fn size(&self) -> (u32, u32) {
        let (w, h) = self.mode.size();
        (u32::from(w), u32::from(h))
    }
}

#[derive(Debug)]
pub enum Error {
    /// A DRM ioctl failed.
    Drm(io::Error),
    /// No connector reports a connected panel.
    NoConnector,
    /// The connected connector has no modes.
    NoMode,
    /// Neither the connector's encoder nor the device offers a CRTC.
    NoCrtc,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Drm(e) => write!(f, "drm: {e}"),
            Error::NoConnector => f.write_str("no connected connector"),
            Error::NoMode => f.write_str("connected connector has no modes"),
            Error::NoCrtc => f.write_str("no usable crtc"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Drm(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Drm(e)
    }
}
