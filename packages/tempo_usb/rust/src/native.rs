use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use rusb::{Device, DeviceHandle, GlobalContext};
use serde_json::{Value, json};

use crate::{Endpoint, Interface, Layout, Result, Transport, is_candidate, select_layout};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(500);

pub(crate) fn open_when_accessible<T>(
    mut open: impl FnMut() -> std::result::Result<T, rusb::Error>,
    cancelled: &AtomicBool,
    timeout: Duration,
) -> std::result::Result<T, rusb::Error> {
    let started = Instant::now();
    loop {
        if cancelled.load(Ordering::Relaxed) {
            return Err(rusb::Error::Interrupted);
        }
        match open() {
            Err(rusb::Error::Access) if started.elapsed() < timeout => {
                std::thread::sleep(
                    Duration::from_millis(20).min(timeout.saturating_sub(started.elapsed())),
                );
            }
            result => return result,
        }
    }
}

struct ReadBoundary {
    active: bool,
    synchronized: bool,
    deadline: Option<Instant>,
}
impl Default for ReadBoundary {
    fn default() -> Self {
        Self {
            active: false,
            synchronized: true,
            deadline: None,
        }
    }
}
impl ReadBoundary {
    fn begin(&mut self, cancelled: bool, now: Instant) -> Result<()> {
        if !self.synchronized {
            return Err("DA read is not synchronized; recovery is required".into());
        }
        if cancelled {
            return Err("Connection check stopped".into());
        }
        self.active = true;
        self.synchronized = false;
        self.deadline = Some(now + Duration::from_secs(20));
        Ok(())
    }
    fn finish(&mut self, synchronized: bool) {
        self.active = false;
        self.synchronized = synchronized;
        self.deadline = None;
    }
    fn begin_cleanup(&mut self, now: Instant) -> Result<()> {
        if !self.synchronized {
            return Err("DA read did not finish; reboot was not sent. Reconnect or reset the player for recovery".into());
        }
        self.deadline = Some(now + Duration::from_secs(5));
        Ok(())
    }
    fn timeout(&self, regular: Duration, now: Instant) -> Result<Duration> {
        match self.deadline {
            Some(deadline) => deadline
                .checked_duration_since(now)
                // libusb interprets a zero-millisecond timeout as unlimited.
                .filter(|left| *left >= Duration::from_millis(1))
                .map(|left| regular.min(left))
                .ok_or_else(|| "DA transaction deadline exceeded".into()),
            None => Ok(regular),
        }
    }
}

#[derive(Default)]
struct ReadMetrics {
    payload_bytes: u64,
    payload_us: u128,
    status_us: u128,
    write_us: u128,
    payload_transfers: u64,
}

pub struct NativePort {
    handle: DeviceHandle<GlobalContext>,
    pub layout: Layout,
    claimed: Vec<u8>,
    input_packet_size: usize,
    buffered: Vec<u8>,
    cancelled: Arc<AtomicBool>,
    transfer_timeout: Duration,
    read_boundary: ReadBoundary,
    metrics: ReadMetrics,
}

pub fn candidates() -> Result<Vec<Device<GlobalContext>>> {
    Ok(rusb::devices()
        .map_err(|e| e.to_string())?
        .iter()
        .filter(|d| {
            d.device_descriptor()
                .is_ok_and(|i| is_candidate(i.vendor_id(), i.product_id()))
        })
        .collect())
}

impl NativePort {
    pub fn open(
        device: Device<GlobalContext>,
        cancelled: Arc<AtomicBool>,
    ) -> Result<(Self, Value)> {
        let descriptor = device.device_descriptor().map_err(|e| e.to_string())?;
        // The prototype supports a single configuration; never change an
        // unrelated composite device's active configuration by guessing.
        if descriptor.num_configurations() != 1 {
            return Err("Expected one USB configuration".into());
        }
        let config = device.config_descriptor(0).map_err(|e| e.to_string())?;
        let interfaces: Vec<_> = config
            .interfaces()
            .flat_map(|i| {
                i.descriptors().map(|d| Interface {
                    number: d.interface_number(),
                    alternate: d.setting_number(),
                    class: d.class_code(),
                    endpoints: d
                        .endpoint_descriptors()
                        .map(|e| Endpoint {
                            address: e.address(),
                            bulk: e.transfer_type() == rusb::TransferType::Bulk,
                        })
                        .collect(),
                })
            })
            .collect();
        let layout = select_layout(&interfaces)?;
        let input_packet_size = config
            .interfaces()
            .flat_map(|i| i.descriptors())
            .filter(|d| {
                d.interface_number() == layout.interface && d.setting_number() == layout.alternate
            })
            .flat_map(|d| d.endpoint_descriptors())
            .find(|e| e.address() == layout.input)
            .map(|e| usize::from(e.max_packet_size()))
            .filter(|n| *n > 0)
            .ok_or("Missing input endpoint packet size")?;
        // Linux publishes the USB node before udev has applied its access
        // rules. Retry only access failures, before claiming interfaces
        // or sending data.
        let handle = open_when_accessible(
            || device.open(),
            &cancelled,
            Duration::from_secs(1),
        ).map_err(|e| {
            if cancelled.load(Ordering::Relaxed) {
                return "USB connection cancelled".to_string();
            }
            format!(
                "Cannot open USB device {:04x}:{:04x} (bus {}, address {}): {e}. {}",
                descriptor.vendor_id(), descriptor.product_id(),
                device.bus_number(), device.address(),
                if e == rusb::Error::Access {
                    "Access is still denied after waiting for device permissions. Check the host USB access rules, then reconnect the player."
                } else {
                    "Reconnect the player and check for another application using it."
                }
            )
        })?;
        // libusb reattaches detached kernel drivers when the interface is
        // released.
        match handle.set_auto_detach_kernel_driver(true) {
            Ok(()) | Err(rusb::Error::NotSupported) => {}
            Err(e) => return Err(e.to_string()),
        }
        if handle.active_configuration().map_err(|e| e.to_string())? != config.number() {
            handle
                .set_active_configuration(config.number())
                .map_err(|e| e.to_string())?;
        }
        let mut port = Self {
            handle,
            layout: layout.clone(),
            claimed: vec![],
            input_packet_size,
            buffered: vec![],
            cancelled,
            transfer_timeout: HANDSHAKE_TIMEOUT,
            read_boundary: ReadBoundary::default(),
            metrics: ReadMetrics::default(),
        };
        let mut claims = vec![layout.interface];
        if let Some(control) = layout.control
            && !claims.contains(&control)
        {
            claims.push(control);
        }
        for interface in claims {
            port.handle
                .claim_interface(interface)
                .map_err(|e| format!("Cannot claim USB interface {interface}: {e}"))?;
            port.claimed.push(interface);
        }
        if layout.alternate != 0 {
            port.handle
                .set_alternate_setting(layout.interface, layout.alternate)
                .map_err(|e| e.to_string())?;
        }
        // Avoid string requests on the capture path: serial descriptors can be
        // inspected after the handshake and must not consume the boot window.
        let info = json!({"vendor_id": descriptor.vendor_id(), "product_id": descriptor.product_id(),
            "serial_descriptor_present": descriptor.serial_number_string_index().is_some(),
            "bus": device.bus_number(), "address": device.address(), "interfaces": interfaces, "layout": layout});
        Ok((port, info))
    }
    fn check_cancelled(&self) -> Result<()> {
        if !self.read_boundary.active && self.cancelled.load(Ordering::Relaxed) {
            Err("Connection check stopped".into())
        } else {
            Ok(())
        }
    }

    /// The preloader handshake needs a short deadline, while eMMC erase,
    /// program, and read-back operations can legitimately take several
    /// seconds between protocol responses.
    pub fn set_transfer_timeout(&mut self, timeout: Duration) {
        self.transfer_timeout = timeout;
    }
    /// Never send a new command into an unfinished DA read. A failed cleanup
    /// is reported to the caller, with an absolute deadline inside the desktop
    /// adapter's 30-second cooperative grace (20 seconds read + 5 cleanup).
    pub async fn reboot_after_read(&mut self) -> Result<()> {
        self.read_boundary.begin_cleanup(Instant::now())?;
        let result = crate::da::reboot(self).await;
        self.read_boundary.deadline = None;
        result
    }
}

impl Transport for NativePort {
    fn begin_read_transaction(&mut self) -> Result<()> {
        self.read_boundary
            .begin(self.cancelled.load(Ordering::Relaxed), Instant::now())
    }
    fn finish_read_transaction(&mut self, synchronized: bool) -> Result<()> {
        self.read_boundary.finish(synchronized);
        if synchronized && self.metrics.payload_bytes >= 64 * 1024 * 1024 {
            println!(
                "{}",
                json!({
                    "event": "backup-usb-timing",
                    "message": "Backup USB read timing",
                    "bytes": self.metrics.payload_bytes,
                    "payload_ms": self.metrics.payload_us as f64 / 1000.0,
                    "status_ms": self.metrics.status_us as f64 / 1000.0,
                    "command_write_ms": self.metrics.write_us as f64 / 1000.0,
                    "payload_transfers": self.metrics.payload_transfers,
                    "max_receive_bytes": 1024 * 1024,
                })
            );
            self.metrics = ReadMetrics::default();
        }
        self.check_cancelled()
    }
    async fn read(&mut self, length: usize) -> Result<Vec<u8>> {
        self.check_cancelled()?;
        self.read_boundary
            .timeout(self.transfer_timeout, Instant::now())?;
        let read_started = std::time::Instant::now();
        while self.buffered.is_empty() {
            self.check_cancelled()?;
            if read_started.elapsed() >= self.transfer_timeout {
                return Err("USB read timed out after empty packets".into());
            }
            let receive_size = length
                .clamp(1, 1024 * 1024)
                .div_ceil(self.input_packet_size)
                * self.input_packet_size;
            let mut buffer = vec![0; receive_size];
            let transfer_started = Instant::now();
            let count = self
                .handle
                .read_bulk(
                    self.layout.input,
                    &mut buffer,
                    self.read_boundary
                        .timeout(self.transfer_timeout, Instant::now())?,
                )
                .map_err(|e| e.to_string())?;
            if length >= 512 {
                self.metrics.payload_bytes += count as u64;
                self.metrics.payload_us += transfer_started.elapsed().as_micros();
                self.metrics.payload_transfers += 1;
            } else {
                self.metrics.status_us += transfer_started.elapsed().as_micros();
            }
            buffer.truncate(count);
            self.buffered = buffer;
        }
        if length >= self.buffered.len() {
            return Ok(std::mem::take(&mut self.buffered));
        }
        Ok(self.buffered.drain(..length).collect())
    }

    async fn write(&mut self, data: &[u8]) -> Result<()> {
        self.check_cancelled()?;
        let transfer_started = Instant::now();
        let count = self
            .handle
            .write_bulk(
                self.layout.output,
                data,
                self.read_boundary
                    .timeout(self.transfer_timeout, Instant::now())?,
            )
            .map_err(|e| e.to_string())?;
        self.metrics.write_us += transfer_started.elapsed().as_micros();
        if count != data.len() {
            return Err("Short USB write".into());
        }
        Ok(())
    }
    async fn control(&mut self, request: u8, value: u16, index: u16, data: &[u8]) -> Result<()> {
        self.check_cancelled()?;
        let count = self
            .handle
            .write_control(
                0x21,
                request,
                value,
                index,
                data,
                self.read_boundary
                    .timeout(self.transfer_timeout, Instant::now())?,
            )
            .map_err(|e| e.to_string())?;
        if count != data.len() {
            return Err("Short USB control transfer".into());
        }
        Ok(())
    }
}

impl Drop for NativePort {
    fn drop(&mut self) {
        for interface in self.claimed.iter().rev() {
            let _ = self.handle.release_interface(*interface);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn usb_open_retries_only_access_errors() {
        let cancelled = AtomicBool::new(false);
        let mut attempts = 0;
        let result = open_when_accessible(
            || {
                attempts += 1;
                if attempts == 1 {
                    Err(rusb::Error::Access)
                } else {
                    Ok(42)
                }
            },
            &cancelled,
            Duration::from_secs(1),
        );
        assert_eq!(result, Ok(42));
        assert_eq!(attempts, 2);
        assert_eq!(
            open_when_accessible::<()>(
                || Err(rusb::Error::NoDevice),
                &cancelled,
                Duration::from_secs(1)
            ),
            Err(rusb::Error::NoDevice)
        );
        assert_eq!(
            open_when_accessible::<()>(|| Err(rusb::Error::Access), &cancelled, Duration::ZERO),
            Err(rusb::Error::Access)
        );
        cancelled.store(true, Ordering::Relaxed);
        assert_eq!(
            open_when_accessible::<()>(
                || panic!("must not open after cancellation"),
                &cancelled,
                Duration::from_secs(1)
            ),
            Err(rusb::Error::Interrupted)
        );
    }

    #[test]
    fn read_deadline_is_absolute_and_failed_transaction_requires_recovery() {
        let now = Instant::now();
        let mut boundary = ReadBoundary::default();
        assert!(boundary.begin(true, now).is_err());
        assert!(boundary.synchronized);
        boundary.begin(false, now).unwrap();
        assert!(!boundary.synchronized);
        assert_eq!(
            boundary
                .timeout(Duration::from_secs(10), now + Duration::from_secs(19))
                .unwrap(),
            Duration::from_secs(1)
        );
        assert!(
            boundary
                .timeout(Duration::from_secs(10), now + Duration::from_secs(20))
                .is_err()
        );
        boundary.finish(false);
        assert!(!boundary.active);
        assert!(!boundary.synchronized);
        assert!(boundary.begin(false, now).is_err());
        assert!(
            boundary
                .begin_cleanup(now)
                .unwrap_err()
                .contains("reboot was not sent")
        );
    }
    #[test]
    fn complete_ack_restores_idle_boundary() {
        let now = Instant::now();
        let mut boundary = ReadBoundary::default();
        boundary.begin(false, now).unwrap();
        boundary.finish(true);
        assert!(!boundary.active);
        assert!(boundary.synchronized);
        assert!(boundary.deadline.is_none());
        boundary.begin_cleanup(now).unwrap();
        assert_eq!(
            boundary.timeout(Duration::from_secs(10), now).unwrap(),
            Duration::from_secs(5)
        );
        assert!(
            boundary
                .timeout(
                    Duration::from_secs(10),
                    now + Duration::from_micros(4_999_500)
                )
                .is_err()
        );
    }
}
