//! In-process client for the recovery firmware's dedicated FunctionFS bulk
//! port. No subprocesses, serial-device paths, or host network configuration
//! required.
use std::{
    io::{Read, Write},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use crate::Result;
const CHUNK: usize = 1024 * 1024;
const INFO: u32 = 1;
const BEGIN_READ: u32 = 2;
const BEGIN_WRITE: u32 = 3;
const READ: u32 = 4;
const WRITE: u32 = 5;
const ACK: u32 = 6;
const FINISH: u32 = 7;
const CANCEL: u32 = 8;
const CONTEXT: u32 = 9;
const FILL: u32 = 10;
const REBOOT: u32 = 11;

fn crc(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, item) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ if c & 1 != 0 { 0xedb88320 } else { 0 };
        }
        *item = c;
    }
    let mut c = !0u32;
    for b in data {
        c = table[((c ^ u32::from(*b)) & 255) as usize] ^ (c >> 8);
    }
    !c
}
#[derive(Clone, Copy, Debug)]
pub enum Region {
    User = 0,
    Boot0 = 1,
    Boot1 = 2,
}
#[derive(Debug)]
pub struct Progress {
    pub completed: u64,
    pub total: u64,
    pub bytes_per_second: f64,
}
/// Transport adapters may use an already-authorized native USB handle on
/// mobile.
pub trait BulkTransport {
    fn send(&mut self, bytes: &[u8]) -> Result<()>;
    fn receive(&mut self, bytes: &mut [u8]) -> Result<()>;
}
pub struct UsbBulk {
    handle: rusb::DeviceHandle<rusb::GlobalContext>,
    interface: u8,
    input: u8,
    output: u8,
}
impl UsbBulk {
    pub fn open() -> Result<Self> {
        let devices = rusb::devices().map_err(|e| e.to_string())?;
        let mut matches = Vec::new();
        for device in devices.iter() {
            let descriptor = device.device_descriptor().map_err(|e| e.to_string())?;
            if descriptor.vendor_id() != 0x0525 || descriptor.product_id() != 0xa4aa {
                continue;
            }
            let config = device
                .active_config_descriptor()
                .map_err(|e| e.to_string())?;
            for interface in config.interfaces() {
                for alt in interface.descriptors() {
                    if alt.class_code() != 0xff
                        || alt.sub_class_code() != 0x54
                        || alt.protocol_code() != 1
                    {
                        continue;
                    }
                    let mut input = None;
                    let mut output = None;
                    for ep in alt.endpoint_descriptors() {
                        if ep.transfer_type() != rusb::TransferType::Bulk {
                            continue;
                        }
                        match ep.direction() {
                            rusb::Direction::In => input = Some(ep.address()),
                            rusb::Direction::Out => output = Some(ep.address()),
                        }
                    }
                    if let (Some(input), Some(output)) = (input, output) {
                        matches.push((
                            device.clone(),
                            alt.interface_number(),
                            alt.setting_number(),
                            input,
                            output,
                        ));
                    }
                }
            }
        }
        if matches.len() != 1 {
            return Err(format!(
                "Expected one Tempo Recovery device, found {}",
                matches.len()
            ));
        }
        let (device, interface, alternate, input, output) = matches.pop().unwrap();
        let handle = crate::native::open_when_accessible(
            || device.open(), &AtomicBool::new(false), Duration::from_secs(1),
        ).map_err(|e| format!("Open Tempo Recovery: {e}. On Linux, install toolbox/linux/70-tempo-recovery.rules into /etc/udev/rules.d, reload udev rules and reconnect the player."))?;
        handle
            .claim_interface(interface)
            .map_err(|e| format!("Claim recovery transfer interface: {e}"))?;
        if alternate != 0
            && let Err(e) = handle.set_alternate_setting(interface, alternate)
        {
            let _ = handle.release_interface(interface);
            return Err(e.to_string());
        }
        Ok(Self {
            handle,
            interface,
            input,
            output,
        })
    }
}
impl Drop for UsbBulk {
    fn drop(&mut self) {
        let _ = self.handle.release_interface(self.interface);
    }
}
impl BulkTransport for UsbBulk {
    fn send(&mut self, mut bytes: &[u8]) -> Result<()> {
        while !bytes.is_empty() {
            let n = self
                .handle
                .write_bulk(
                    self.output,
                    &bytes[..bytes.len().min(65536)],
                    Duration::from_secs(30),
                )
                .map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("Recovery USB write stalled".into());
            }
            bytes = &bytes[n..];
        }
        Ok(())
    }
    fn receive(&mut self, mut bytes: &mut [u8]) -> Result<()> {
        while !bytes.is_empty() {
            let size = bytes.len().min(65536);
            let n = self
                .handle
                .read_bulk(self.input, &mut bytes[..size], Duration::from_secs(30))
                .map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("Recovery USB read stalled".into());
            }
            bytes = &mut bytes[n..];
        }
        Ok(())
    }
}
pub struct Client<T: BulkTransport> {
    transport: T,
    active: bool,
    context_supported: bool,
    fill_supported: bool,
    reboot_supported: bool,
}
impl<T: BulkTransport> Client<T> {
    pub fn new(transport: T) -> Self {
        Self {
            transport,
            active: false,
            context_supported: false,
            fill_supported: false,
            reboot_supported: false,
        }
    }
    fn command(
        &mut self,
        op: u32,
        region: Region,
        offset: u64,
        length: u64,
        flags: u32,
        data: &[u8],
    ) -> Result<(u64, Vec<u8>)> {
        let mut h = [0u8; 48];
        h[..8].copy_from_slice(b"TEMPREC1");
        h[8..12].copy_from_slice(&op.to_le_bytes());
        h[16..24].copy_from_slice(&offset.to_le_bytes());
        h[24..32].copy_from_slice(&length.to_le_bytes());
        h[32..36].copy_from_slice(&(data.len() as u32).to_le_bytes());
        h[36..40].copy_from_slice(&crc(data).to_le_bytes());
        h[40..44].copy_from_slice(&(region as u32).to_le_bytes());
        h[44..48].copy_from_slice(&flags.to_le_bytes());
        self.transport.send(&h)?;
        if !data.is_empty() {
            self.transport.send(data)?;
        }
        self.transport.receive(&mut h).map_err(|e| format!("Recovery command {op} at offset 0x{offset:x} ({length} bytes): {e}. Retry once Recovery Ready appears."))?;
        let u32at = |i| u32::from_le_bytes(h[i..i + 4].try_into().unwrap());
        if &h[..8] != b"TEMPREC1" || u32at(8) != op | 0x80000000 {
            return Err("Invalid recovery response header".into());
        }
        let size = u32at(32) as usize;
        if size > CHUNK {
            return Err("Oversized recovery response".into());
        }
        let mut payload = vec![0; size];
        if size > 0 {
            self.transport.receive(&mut payload)?;
        }
        if crc(&payload) != u32at(36) {
            return Err("Recovery response checksum mismatch".into());
        }
        if u32at(12) != 0 {
            self.active = false;
            return Err(String::from_utf8_lossy(&payload).into_owned());
        }
        Ok((u64::from_le_bytes(h[16..24].try_into().unwrap()), payload))
    }
    pub fn info(&mut self) -> Result<serde_json::Value> {
        let (_, data) = self.command(INFO, Region::User, 0, 0, 0, &[])?;
        let info: serde_json::Value = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
        self.context_supported = info["context"].as_bool() == Some(true);
        self.fill_supported = info["fill"].as_bool() == Some(true);
        self.reboot_supported = info["reboot"].as_bool() == Some(true);
        Ok(info)
    }
    pub fn set_context(&mut self, title: &str, detail: &str) -> Result<()> {
        if !self.context_supported {
            return Ok(());
        }
        if self.active
            || title.is_empty()
            || title.len() > 63
            || detail.len() > 95
            || !title
                .bytes()
                .chain(detail.bytes())
                .all(|b| (32..=126).contains(&b))
        {
            return Err("Invalid recovery display context".into());
        }
        self.command(
            CONTEXT,
            Region::User,
            0,
            0,
            0,
            format!("{title}\n{detail}").as_bytes(),
        )?;
        Ok(())
    }
    pub fn reboot(&mut self) -> Result<bool> {
        if !self.reboot_supported {
            return Ok(false);
        }
        if self.active {
            return Err("Cannot reboot an active transfer".into());
        }
        self.command(REBOOT, Region::User, 0, 0, 0, &[])?;
        Ok(true)
    }
    pub fn cancel(&mut self) -> Result<()> {
        if self.active {
            self.command(CANCEL, Region::User, 0, 0, 0, &[])?;
            self.active = false;
        }
        Ok(())
    }
    pub fn read_region(
        &mut self,
        region: Region,
        offset: u64,
        total: u64,
        sink: &mut impl Write,
        cancel: &AtomicBool,
        progress: &mut impl FnMut(Progress),
    ) -> Result<()> {
        self.transfer(
            region,
            offset,
            total,
            false,
            false,
            false,
            &mut std::io::empty(),
            sink,
            cancel,
            progress,
        )
    }
    /// Preloader writes require firmware opt-in and per-operation consent.
    #[allow(clippy::too_many_arguments)]
    pub fn write_region(
        &mut self,
        region: Region,
        offset: u64,
        total: u64,
        source: &mut impl Read,
        allow_boot: bool,
        verify: bool,
        cancel: &AtomicBool,
        progress: &mut impl FnMut(Progress),
    ) -> Result<()> {
        self.transfer(
            region,
            offset,
            total,
            true,
            allow_boot,
            verify,
            source,
            &mut std::io::sink(),
            cancel,
            progress,
        )
    }
    #[allow(clippy::too_many_arguments)]
    fn transfer(
        &mut self,
        region: Region,
        offset: u64,
        total: u64,
        writing: bool,
        allow_boot: bool,
        verify: bool,
        source: &mut impl Read,
        sink: &mut impl Write,
        cancel: &AtomicBool,
        progress: &mut impl FnMut(Progress),
    ) -> Result<()> {
        if self.active
            || total == 0
            || !total.is_multiple_of(512)
            || !offset.is_multiple_of(512)
            || offset.checked_add(total).is_none()
        {
            return Err("Invalid recovery transfer range".into());
        }
        if cancel.load(Ordering::Relaxed) {
            return Err("Operation cancelled".into());
        }
        self.command(
            if writing { BEGIN_WRITE } else { BEGIN_READ },
            region,
            offset,
            total,
            u32::from(allow_boot) | (u32::from(verify) << 1),
            &[],
        )?;
        self.active = true;
        let result = (|| {
            let mut completed = 0;
            let mut buffer = vec![0u8; CHUNK];
            let mut sampled = Instant::now();
            let mut sampled_done = 0;
            let mut speed = 0.0;
            progress(Progress {
                completed,
                total,
                bytes_per_second: 0.0,
            });
            while completed < total {
                if cancel.load(Ordering::Relaxed) {
                    return Err("Operation cancelled".into());
                }
                let n = (total - completed).min(CHUNK as u64) as usize;
                let acknowledged = if writing {
                    source
                        .read_exact(&mut buffer[..n])
                        .map_err(|e| e.to_string())?;
                    if self.fill_supported
                        && buffer[..n]
                            .as_chunks::<4>()
                            .0
                            .iter()
                            .all(|v| v == &buffer[..4])
                    {
                        self.command(FILL, region, offset + completed, n as u64, 0, &buffer[..4])?
                            .0
                    } else {
                        self.command(WRITE, region, offset + completed, n as u64, 0, &buffer[..n])?
                            .0
                    }
                } else {
                    let (_, data) =
                        self.command(READ, region, offset + completed, n as u64, 0, &[])?;
                    if data.len() != n {
                        return Err("Short recovery data chunk".into());
                    }
                    sink.write_all(&data).map_err(|e| e.to_string())?;
                    self.command(ACK, region, offset + completed + n as u64, 0, 0, &[])?
                        .0
                };
                completed += n as u64;
                if acknowledged != completed {
                    return Err("Recovery progress acknowledgement mismatch".into());
                }
                let elapsed = sampled.elapsed().as_secs_f64();
                if elapsed >= 0.2 || completed == total {
                    speed = (completed - sampled_done) as f64 / elapsed.max(0.001);
                    sampled = Instant::now();
                    sampled_done = completed;
                }
                progress(Progress {
                    completed,
                    total,
                    bytes_per_second: speed,
                });
            }
            sink.flush().map_err(|e| e.to_string())?;
            self.command(FINISH, region, 0, 0, 0, &[])?;
            self.active = false;
            Ok(())
        })();
        if result.is_err() {
            let _ = self.cancel();
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn standard_crc() {
        assert_eq!(crc(b"123456789"), 0xcbf43926);
        assert_eq!(crc(b""), 0);
    }
    struct Fake {
        input: std::io::Cursor<Vec<u8>>,
        sent: Vec<u8>,
    }
    impl BulkTransport for Fake {
        fn send(&mut self, b: &[u8]) -> Result<()> {
            self.sent.extend(b);
            Ok(())
        }
        fn receive(&mut self, b: &mut [u8]) -> Result<()> {
            self.input.read_exact(b).map_err(|e| e.to_string())
        }
    }
    fn response(op: u32, done: u64, payload: &[u8]) -> Vec<u8> {
        let mut h = vec![0; 48];
        h[..8].copy_from_slice(b"TEMPREC1");
        h[8..12].copy_from_slice(&(op | 0x80000000).to_le_bytes());
        h[16..24].copy_from_slice(&done.to_le_bytes());
        h[32..36].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        h[36..40].copy_from_slice(&crc(payload).to_le_bytes());
        h.extend(payload);
        h
    }
    #[test]
    fn fill_payload_is_four_bytes_and_old_recovery_uses_raw_writes() {
        for supported in [true, false] {
            let info = if supported {
                b"{\"fill\":true}".as_slice()
            } else {
                b"{}".as_slice()
            };
            let op = if supported { FILL } else { WRITE };
            let input = [
                response(INFO, 0, info),
                response(BEGIN_WRITE, 0, &[]),
                response(op, 512, &[]),
                response(FINISH, 512, &[]),
            ]
            .concat();
            let mut c = Client::new(Fake {
                input: std::io::Cursor::new(input),
                sent: vec![],
            });
            c.info().unwrap();
            c.write_region(
                Region::User,
                0,
                512,
                &mut vec![0u8; 512].as_slice(),
                false,
                true,
                &AtomicBool::new(false),
                &mut |_| {},
            )
            .unwrap();
            let sent = &c.transport.sent;
            assert_eq!(u32::from_le_bytes(sent[104..108].try_into().unwrap()), op);
            assert_eq!(
                u32::from_le_bytes(sent[128..132].try_into().unwrap()),
                if supported { 4 } else { 512 }
            );
        }
    }
    #[test]
    fn rejects_oversized_response() {
        let mut h = vec![0; 48];
        h[..8].copy_from_slice(b"TEMPREC1");
        h[8..12].copy_from_slice(&(INFO | 0x80000000).to_le_bytes());
        h[32..36].copy_from_slice(&((CHUNK + 1) as u32).to_le_bytes());
        let mut c = Client::new(Fake {
            input: std::io::Cursor::new(h),
            sent: vec![],
        });
        assert!(c.info().unwrap_err().contains("Oversized"));
    }
}
