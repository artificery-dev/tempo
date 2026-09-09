//! Legacy MT6582 DA parsing, session initialization, and bounded eMMC I/O.
//! Wire layout is checked against the successful SPFT capture.
use serde::Serialize;

use crate::{ProbeReport, Result, Transport, read_exact};

pub struct Region<'a> {
    pub address: u32,
    pub signature_length: u32,
    pub bytes: &'a [u8],
}
pub struct Agent<'a> {
    pub first: Region<'a>,
    pub second: Region<'a>,
}
fn le16(b: &[u8], o: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(
        b.get(o..o + 2)
            .ok_or("Truncated DA header")?
            .try_into()
            .unwrap(),
    ))
}
fn le32(b: &[u8], o: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        b.get(o..o + 4)
            .ok_or("Truncated DA header")?
            .try_into()
            .unwrap(),
    ))
}
impl<'a> Agent<'a> {
    pub fn parse(bytes: &'a [u8], chip: &ProbeReport) -> Result<Self> {
        if chip.hardware_code != 0x6582 {
            return Err("Only MT6582 download agents are supported".into());
        }
        let count = le32(bytes, 0x68)? as usize;
        if count == 0 || count > 1024 {
            return Err("Invalid DA entry count".into());
        }
        let mut found = None;
        for i in 0..count {
            let o = 0x6c + i * 0xdc;
            if le16(bytes, o)? != 0xdada {
                return Err("Unsupported DA container format".into());
            }
            if le16(bytes, o + 2)? != chip.hardware_code {
                continue;
            }
            if le16(bytes, o + 6)? > chip.hardware_version
                || le16(bytes, o + 8)? > chip.software_version
            {
                continue;
            }
            let sub = le16(bytes, o + 4)?;
            if sub != 0 && sub != chip.hardware_subcode {
                continue;
            }
            if found.is_some() {
                return Err("Ambiguous matching DA entries".into());
            }
            if le16(bytes, o + 18)? != 3 {
                return Err("Unexpected DA region count".into());
            }
            let region = |index: usize| -> Result<Region<'a>> {
                let p = o + 20 + index * 20;
                let offset = le32(bytes, p)? as usize;
                let length = le32(bytes, p + 4)? as usize;
                let signature_length = le32(bytes, p + 16)?;
                if length == 0 || signature_length as usize > length {
                    return Err("Invalid DA region length".into());
                }
                Ok(Region {
                    address: le32(bytes, p + 8)?,
                    signature_length,
                    bytes: bytes
                        .get(offset..offset.checked_add(length).ok_or("DA size overflow")?)
                        .ok_or("Truncated DA region")?,
                })
            };
            let first = region(1)?;
            let second = region(2)?;
            if first.address != 0x200000 || second.address != 0x80000000 {
                return Err("Unsupported Y2 DA load addresses".into());
            }
            found = Some(Self { first, second });
        }
        found.ok_or("No matching MT6582 DA entry".into())
    }
}
pub(crate) async fn expect(p: &mut impl Transport, expected: &[u8], stage: &str) -> Result<()> {
    let actual = read_exact(p, expected.len()).await?;
    if actual != expected {
        return Err(format!("{stage}: unexpected response {actual:02x?}"));
    }
    Ok(())
}
async fn echo(p: &mut impl Transport, bytes: &[u8]) -> Result<()> {
    p.write(bytes).await?;
    expect(p, bytes, "DA command echo").await
}
#[derive(Debug, Serialize)]
pub struct Geometry {
    pub user: u64,
    pub boot1: u64,
    pub boot2: u64,
    pub rpmb: u64,
}

impl Geometry {
    pub fn is_y2(&self) -> bool {
        self.user == 0x1d2000000
            && self.boot1 == 0x400000
            && self.boot2 == 0x400000
            && self.rpmb == 0x80000
    }

    pub fn image_size(&self) -> Result<u64> {
        self.boot1
            .checked_add(self.boot2)
            .and_then(|n| n.checked_add(self.rpmb))
            .and_then(|n| n.checked_add(self.user))
            .ok_or_else(|| "eMMC capacity overflow".into())
    }
}

pub async fn initialize(p: &mut impl Transport, agent: &Agent<'_>) -> Result<Geometry> {
    initialize_with_emi(p, agent, None).await
}
pub async fn initialize_with_emi(
    p: &mut impl Transport,
    agent: &Agent<'_>,
    emi: Option<&crate::emi::Emi>,
) -> Result<Geometry> {
    upload_stages(p, agent, emi).await?;
    finish_initialization(p).await
}

/// Experimental RAM boot: use the vendor first stage only for DRAM setup and
/// upload a replacement executable at its normal second-stage address.
/// This does not issue any eMMC write, erase, or reboot command.
pub async fn boot_ram(
    p: &mut impl Transport,
    agent: &Agent<'_>,
    emi: Option<&crate::emi::Emi>,
    payload: &[u8],
) -> Result<()> {
    boot_ram_with_progress(p, agent, emi, payload, &mut |_, _, _| {}).await
}

pub async fn boot_ram_with_progress(
    p: &mut impl Transport,
    agent: &Agent<'_>,
    emi: Option<&crate::emi::Emi>,
    payload: &[u8],
    progress: &mut impl FnMut(&str, usize, usize),
) -> Result<()> {
    if payload.len() < 260 || payload.len() > 32 * 1024 * 1024 {
        return Err("RAM payload must include code and a 256-byte trailer, at most 32 MiB".into());
    }
    let ram_agent = Agent {
        first: Region {
            address: agent.first.address,
            signature_length: agent.first.signature_length,
            bytes: agent.first.bytes,
        },
        second: Region {
            address: 0x80000000,
            signature_length: 0,
            bytes: payload,
        },
    };
    upload_stages_with_progress(p, &ram_agent, emi, progress).await
}

async fn upload_stages(
    p: &mut impl Transport,
    agent: &Agent<'_>,
    emi: Option<&crate::emi::Emi>,
) -> Result<()> {
    upload_stages_with_progress(p, agent, emi, &mut |_, _, _| {}).await
}

async fn upload_stages_with_progress(
    p: &mut impl Transport,
    agent: &Agent<'_>,
    emi: Option<&crate::emi::Emi>,
    progress: &mut impl FnMut(&str, usize, usize),
) -> Result<()> {
    progress("Downloading download agent", 0, agent.first.bytes.len());
    echo(p, &[0xd8]).await?;
    let security = read_exact(p, 4).await?;
    expect(p, &[0, 0], "Security query status").await?;
    if security != [0, 0, 0, 0] {
        return Err("This prototype does not support authenticated DA loading".into());
    }
    echo(p, &[0xd7]).await?;
    echo(p, &agent.first.address.to_be_bytes()).await?;
    echo(p, &(agent.first.bytes.len() as u32).to_be_bytes()).await?;
    echo(p, &agent.first.signature_length.to_be_bytes()).await?;
    expect(p, &[0, 0], "DA upload status").await?;
    let mut checksum = 0u16;
    for pair in agent.first.bytes.chunks(2) {
        checksum ^= u16::from_le_bytes([pair[0], *pair.get(1).unwrap_or(&0)]);
    }
    let mut sent = 0;
    for chunk in agent.first.bytes.chunks(1024) {
        p.write(chunk).await?;
        sent += chunk.len();
        progress("Downloading download agent", sent, agent.first.bytes.len());
    }
    expect(p, &checksum.to_be_bytes(), "DA checksum").await?;
    expect(p, &[0, 0], "DA checksum status").await?;
    echo(p, &[0xd5]).await?;
    echo(p, &agent.first.address.to_be_bytes()).await?;
    expect(p, &[0, 0], "DA jump status").await?;
    expect(p, &[0xc0], "DA startup").await?;
    let _nand_status = read_exact(p, 4).await?;
    let count = u16::from_be_bytes(read_exact(p, 2).await?.try_into().unwrap()) as usize;
    if count > 32 {
        return Err("Invalid NAND identifier count".into());
    }
    let _nand = read_exact(p, count * 2).await?;
    expect(p, &[0, 0, 0, 0], "eMMC detection").await?;
    let _emmc_id = read_exact(p, 16).await?;
    p.write(&[0x5a]).await?;
    expect(p, &[4, 2, 0x87], "DA version").await?;
    // SPFT's Y2 configuration, including AutoDetect battery mode (02).
    for field in [
        vec![0xff],
        vec![1],
        vec![0, 8],
        vec![0],
        vec![0x70, 7, 0xff, 0xff],
        vec![1],
        vec![1, 0x50, 0, 0],
        vec![2],
        vec![1],
        vec![2],
        vec![0],
        vec![0, 0, 0, 0],
    ] {
        p.write(&field).await?;
    }
    let status = read_exact(p, 4).await?.try_into().unwrap();
    crate::emi::initialize_dram(p, status, emi).await?;
    p.write(&agent.second.address.to_be_bytes()).await?;
    p.write(&(agent.second.bytes.len() as u32).to_be_bytes())
        .await?;
    p.write(&4096u32.to_be_bytes()).await?;
    expect(p, &[0x5a], "Second-stage header").await?;
    progress("Downloading Tempo Recovery", 0, agent.second.bytes.len());
    let mut sent = 0;
    for chunk in agent.second.bytes.chunks(4096) {
        p.write(chunk).await?;
        expect(p, &[0x5a], "Second-stage block").await?;
        sent += chunk.len();
        progress("Downloading Tempo Recovery", sent, agent.second.bytes.len());
    }
    // DA1 always receives a remainder and acknowledges it, even if empty.
    // Confirmed at DA1 0x200412..0x20041c. The normal vendor DA has a
    // non-empty remainder; aligned custom payloads require this extra read.
    if agent.second.bytes.len().is_multiple_of(4096) {
        expect(p, &[0x5a], "Empty second-stage remainder").await?;
    }
    Ok(())
}

async fn finish_initialization(p: &mut impl Transport) -> Result<Geometry> {
    expect(p, &[0x5a], "Second-stage completion").await?;
    p.write(&[0x5a]).await?;
    let _nor = read_exact(p, 28).await?;
    // This vendor DA emits the legacy 32-bit NAND record, even on eMMC.
    let nand = read_exact(p, 13).await?;
    let count = u16::from_be_bytes([nand[11], nand[12]]) as usize;
    if count > 32 {
        return Err("Invalid flash identifier count".into());
    }
    let _nand_ids = read_exact(p, count * 2).await?;
    let _nand_config = read_exact(p, 9).await?;
    let emmc = read_exact(p, 92).await?;
    if emmc[..4] != [0, 0, 0, 0] {
        return Err("DA reports an eMMC error".into());
    }
    let size = |o| u64::from_be_bytes(emmc[o..o + 8].try_into().unwrap());
    let geometry = Geometry {
        boot1: size(4),
        boot2: size(12),
        rpmb: size(20),
        user: size(60),
    };
    if geometry.user == 0
        || geometry.user > 128 * 1024 * 1024 * 1024
        || !geometry.user.is_multiple_of(512)
    {
        return Err("Invalid eMMC capacity".into());
    }
    let _sd = read_exact(p, 28).await?;
    let _config = read_exact(p, 38).await?;
    let pass = read_exact(p, 10).await?;
    if pass[0] != 0x5a || pass[9] != 0xc1 {
        return Err("Unexpected DA initialization completion".into());
    }
    Ok(geometry)
}

#[allow(async_fn_in_trait)]
pub trait BackupSink {
    async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<()>;
}

#[allow(async_fn_in_trait)]
pub trait FlashSource {
    /// Return exactly `length` bytes beginning at `offset`.
    async fn chunk(&mut self, offset: u64, length: usize) -> Result<Vec<u8>>;
}

#[allow(async_fn_in_trait)]
pub trait FlashSink {
    async fn progress(&mut self, completed: u64, total: u64) -> Result<()>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WriteRegion {
    pub partition: u8,
    pub capacity: u64,
    pub address: u64,
    pub length: u64,
    pub source_offset: u64,
}

/// Write one bounded, block-aligned range using the legacy DA's generic eMMC
/// data command. The caller supplies the capacity reported by this session,
/// so malformed package offsets cannot reach the wire.
pub async fn write_region(
    p: &mut impl Transport,
    region: WriteRegion,
    source: &mut impl FlashSource,
    sink: &mut impl FlashSink,
) -> Result<()> {
    let WriteRegion {
        partition,
        capacity,
        address,
        length,
        source_offset,
    } = region;
    if !matches!(partition, 1 | 2 | 8)
        || length == 0
        || address.checked_add(length).is_none_or(|end| end > capacity)
        || source_offset.checked_add(length).is_none()
        || !address.is_multiple_of(512)
        || !source_offset.is_multiple_of(512)
        || !length.is_multiple_of(512)
    {
        return Err("Invalid flash region or length".into());
    }

    // Keep the same status probe SPFT and mtkclient issue before an eMMC
    // operation. The generic 0x62 command carries its own physical region.
    p.write(&[0x72]).await?;
    expect(p, &[0x5a], "USB status before write").await?;
    let _speed = read_exact(p, 1).await?;
    for bytes in [
        vec![0x62],
        vec![2], // MTK_DA_STORAGE_EMMC
        vec![partition],
        address.to_be_bytes().to_vec(),
        length.to_be_bytes().to_vec(),
        0x100000u32.to_be_bytes().to_vec(),
    ] {
        p.write(&bytes).await?;
    }
    expect(p, &[0x5a], "Write range").await?;

    let mut completed = 0;
    while completed < length {
        let count = (length - completed).min(0x100000) as usize;
        let bytes = source.chunk(source_offset + completed, count).await?;
        if bytes.len() != count {
            return Err(format!(
                "Firmware source returned {} bytes; expected {count}",
                bytes.len()
            ));
        }
        p.write(&[0x5a]).await?;
        // Large browser transfers are less predictable than the byte stream
        // expected by the DA. Send bounded pieces while retaining one DA
        // checksum for the complete (up to 1 MiB) block.
        for part in bytes.chunks(64 * 1024) {
            p.write(part).await?;
        }
        let checksum = bytes
            .iter()
            .fold(0u16, |sum, byte| sum.wrapping_add(u16::from(*byte)));
        p.write(&checksum.to_be_bytes()).await?;
        expect(p, &[0x69], "Write block checksum").await?;
        completed += count as u64;
        sink.progress(completed, length).await?;
    }
    Ok(())
}

/// Translate a physical eMMC region to the Y2 vendor DA's continuous read view.
pub fn hardware_read_address(
    geometry: &Geometry,
    partition: u8,
    address: u64,
    length: u64,
) -> Result<u64> {
    // Public operations validate the Y2 geometry before reaching this adapter.
    // Check the sum before computing any prefix, including for malformed input.
    geometry.image_size()?;
    let (base, capacity) = match partition {
        1 => (0, geometry.boot1),
        2 => (geometry.boot1, geometry.boot2),
        8 => (
            geometry.boot1 + geometry.boot2 + geometry.rpmb,
            geometry.user,
        ),
        _ => return Err("Unsupported physical read region".into()),
    };
    if length == 0
        || !address.is_multiple_of(512)
        || !length.is_multiple_of(512)
        || address.checked_add(length).is_none_or(|end| end > capacity)
    {
        return Err("Physical read exceeds its hardware region or is unaligned".into());
    }
    base.checked_add(address)
        .ok_or("Physical read overflow".into())
}

pub async fn read_hardware_region(
    p: &mut impl Transport,
    geometry: &Geometry,
    partition: u8,
    address: u64,
    length: u64,
    sink: &mut impl BackupSink,
) -> Result<()> {
    let translated = hardware_read_address(geometry, partition, address, length)?;
    read_region(p, 8, geometry.image_size()?, translated, length, sink).await
}

/// Read bytes in the vendor DA's continuous backup address space. The Y2 DA
/// ignores the selected hardware region for this 0xd6 command; physical-region
/// callers must use `read_hardware_region` instead.
pub async fn read_region(
    p: &mut impl Transport,
    partition: u8,
    capacity: u64,
    address: u64,
    length: u64,
    sink: &mut impl BackupSink,
) -> Result<()> {
    if !matches!(partition, 1 | 2 | 8)
        || length == 0
        || address.checked_add(length).is_none_or(|end| end > capacity)
        || !address.is_multiple_of(512)
        || !length.is_multiple_of(512)
    {
        return Err("Invalid backup region or length".into());
    }
    let mut completed = 0;
    while completed < length {
        let count = (length - completed).min(0x100000);
        p.begin_read_transaction()?;
        let read = read_transaction(p, partition, address + completed, count).await;
        let boundary = p.finish_read_transaction(read.is_ok());
        let bytes = read?;
        boundary?;
        completed += count;
        // The whole wire command, including its ACK, is complete before a
        // filesystem write, compression callback, or cancellation can fail.
        sink.chunk(&bytes, completed, length).await?;
    }
    Ok(())
}

async fn read_transaction(
    p: &mut impl Transport,
    partition: u8,
    address: u64,
    length: u64,
) -> Result<Vec<u8>> {
    p.write(&[0x72]).await?;
    expect(p, &[0x5a], "USB status").await?;
    let _speed = read_exact(p, 1).await?;
    p.write(&[0x60]).await?;
    expect(p, &[0x5a], "Select eMMC region").await?;
    p.write(&[partition]).await?;
    expect(p, &[0x5a], "eMMC region selected").await?;
    for bytes in [
        vec![0xd6],
        vec![0x0c],
        vec![2],
        address.to_be_bytes().to_vec(),
        length.to_be_bytes().to_vec(),
    ] {
        p.write(&bytes).await?;
    }
    // The vendor DA acknowledges the range BEFORE accepting chunk size.
    expect(p, &[0x5a], "Read range").await?;
    p.write(&0x100000u32.to_be_bytes()).await?;
    let bytes = read_exact(p, length as usize).await?;
    let checksum = bytes
        .iter()
        .fold(0u16, |sum, b| sum.wrapping_add(u16::from(*b)));
    expect(p, &checksum.to_be_bytes(), "Backup block checksum").await?;
    p.write(&[0x5a]).await?;
    Ok(bytes)
}

/// Match SPFT --reboot: arm the DA watchdog for three seconds.
pub async fn reboot(p: &mut impl Transport) -> Result<()> {
    p.write(&[0xdb]).await?;
    p.write(&[0, 0xc0]).await?;
    p.write(&[0, 0, 0, 0]).await?;
    expect(p, &[0x5a], "DA reboot").await
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;
    enum Exchange {
        Write(Vec<u8>),
        Read(Vec<u8>),
    }
    struct Replay(VecDeque<Exchange>);
    impl Transport for Replay {
        async fn write(&mut self, bytes: &[u8]) -> Result<()> {
            match self.0.pop_front() {
                Some(Exchange::Write(expected)) if expected == bytes => Ok(()),
                _ => Err(format!("Unexpected write {bytes:02x?}")),
            }
        }
        async fn read(&mut self, length: usize) -> Result<Vec<u8>> {
            match self.0.pop_front() {
                Some(Exchange::Read(mut bytes)) => {
                    if bytes.len() > length {
                        let tail = bytes.split_off(length);
                        self.0.push_front(Exchange::Read(tail));
                    }
                    Ok(bytes)
                }
                _ => Err("Read before expected command".into()),
            }
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Err("Unexpected control".into())
        }
    }
    fn chip() -> ProbeReport {
        ProbeReport {
            hardware_code: 0x6582,
            hardware_version: 0xca01,
            hardware_subcode: 0x8a00,
            software_version: 1,
            compatible_chip: true,
            y2_verified: false,
            storage_written: false,
        }
    }
    struct Collect(Vec<u8>);
    impl BackupSink for Collect {
        async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<()> {
            assert_eq!((completed, total), (512, 512));
            self.0.extend_from_slice(bytes);
            Ok(())
        }
    }
    fn read_exchange(address: u64, data: Vec<u8>) -> Vec<Exchange> {
        let checksum = data
            .iter()
            .fold(0u16, |sum, byte| sum.wrapping_add(u16::from(*byte)));
        vec![
            Exchange::Write(vec![0x72]),
            Exchange::Read(vec![0x5a]),
            Exchange::Read(vec![1]),
            Exchange::Write(vec![0x60]),
            Exchange::Read(vec![0x5a]),
            Exchange::Write(vec![8]),
            Exchange::Read(vec![0x5a]),
            Exchange::Write(vec![0xd6]),
            Exchange::Write(vec![0x0c]),
            Exchange::Write(vec![2]),
            Exchange::Write(address.to_be_bytes().to_vec()),
            Exchange::Write((data.len() as u64).to_be_bytes().to_vec()),
            Exchange::Read(vec![0x5a]),
            Exchange::Write(0x100000u32.to_be_bytes().to_vec()),
            Exchange::Read(data),
            Exchange::Read(checksum.to_be_bytes().to_vec()),
            Exchange::Write(vec![0x5a]),
        ]
    }
    struct RecordingSink {
        chunks: Vec<(usize, u64, u64)>,
        fail: bool,
    }
    impl BackupSink for RecordingSink {
        async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<()> {
            self.chunks.push((bytes.len(), completed, total));
            if self.fail {
                Err("disk full".into())
            } else {
                Ok(())
            }
        }
    }
    struct CancelRead {
        replay: Replay,
        cancelled: bool,
        active: bool,
        synchronized: bool,
    }
    impl Transport for CancelRead {
        fn begin_read_transaction(&mut self) -> Result<()> {
            if self.cancelled {
                return Err("cancelled".into());
            }
            self.active = true;
            self.synchronized = false;
            Ok(())
        }
        fn finish_read_transaction(&mut self, synchronized: bool) -> Result<()> {
            self.active = false;
            self.synchronized = synchronized;
            if self.cancelled {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        }
        async fn read(&mut self, length: usize) -> Result<Vec<u8>> {
            if length > 1024 {
                self.cancelled = true;
            }
            self.replay.read(length).await
        }
        async fn write(&mut self, bytes: &[u8]) -> Result<()> {
            if self.cancelled && !self.active {
                return Err("cancelled".into());
            }
            self.replay.write(bytes).await
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            unreachable!()
        }
    }
    #[test]
    fn splits_wire_reads_but_preserves_sink_progress() {
        let mut exchanges = read_exchange(512, vec![7; 0x100000]);
        exchanges.extend(read_exchange(512 + 0x100000, vec![9; 512]));
        let mut replay = Replay(exchanges.into());
        let mut sink = RecordingSink {
            chunks: vec![],
            fail: false,
        };
        pollster::block_on(read_region(
            &mut replay,
            8,
            0x200000,
            512,
            0x100200,
            &mut sink,
        ))
        .unwrap();
        assert_eq!(
            sink.chunks,
            [(0x100000, 0x100000, 0x100200), (512, 0x100200, 0x100200)]
        );
        assert!(replay.0.is_empty());
    }
    #[test]
    fn cancellation_finishes_ack_then_stops_before_next_range_and_can_reboot() {
        let mut exchanges = read_exchange(0, vec![7; 0x100000]);
        exchanges.extend([
            Exchange::Write(vec![0xdb]),
            Exchange::Write(vec![0, 0xc0]),
            Exchange::Write(vec![0; 4]),
            Exchange::Read(vec![0x5a]),
        ]);
        let mut port = CancelRead {
            replay: Replay(exchanges.into()),
            cancelled: false,
            active: false,
            synchronized: true,
        };
        let mut sink = RecordingSink {
            chunks: vec![],
            fail: false,
        };
        assert_eq!(
            pollster::block_on(read_region(&mut port, 8, 0x200000, 0, 0x200000, &mut sink)),
            Err("cancelled".into())
        );
        assert!(port.synchronized);
        assert!(sink.chunks.is_empty());
        port.cancelled = false;
        pollster::block_on(reboot(&mut port)).unwrap();
        assert!(port.replay.0.is_empty());
    }
    #[test]
    fn sink_failure_occurs_after_ack_and_corrupt_checksum_is_not_acknowledged() {
        let mut replay = Replay(read_exchange(0, vec![3; 512]).into());
        let mut sink = RecordingSink {
            chunks: vec![],
            fail: true,
        };
        assert_eq!(
            pollster::block_on(read_region(&mut replay, 8, 512, 0, 512, &mut sink)),
            Err("disk full".into())
        );
        assert!(replay.0.is_empty());
        let mut exchanges = read_exchange(0, vec![3; 512]);
        exchanges.pop(); // no ACK is allowed after a checksum mismatch
        *exchanges.last_mut().unwrap() = Exchange::Read(vec![0, 0]);
        let mut port = CancelRead {
            replay: Replay(exchanges.into()),
            cancelled: false,
            active: false,
            synchronized: true,
        };
        assert!(
            pollster::block_on(read_region(&mut port, 8, 512, 0, 512, &mut sink))
                .unwrap_err()
                .contains("checksum")
        );
        assert!(!port.synchronized);
        assert!(port.replay.0.is_empty());
    }
    struct Bytes(Vec<u8>);
    impl FlashSource for Bytes {
        async fn chunk(&mut self, offset: u64, length: usize) -> Result<Vec<u8>> {
            let start = offset as usize;
            self.0
                .get(start..start + length)
                .map(<[u8]>::to_vec)
                .ok_or_else(|| "Source range is unavailable".into())
        }
    }
    struct Progress(Vec<(u64, u64)>);
    impl FlashSink for Progress {
        async fn progress(&mut self, completed: u64, total: u64) -> Result<()> {
            self.0.push((completed, total));
            Ok(())
        }
    }
    #[test]
    fn reads_an_addressed_region_and_verifies_its_checksum() {
        let data: Vec<_> = (0..512).map(|n| n as u8).collect();
        let checksum = data
            .iter()
            .fold(0u16, |sum, byte| sum.wrapping_add(u16::from(*byte)));
        let mut replay = Replay(
            [
                Exchange::Write(vec![0x72]),
                Exchange::Read(vec![0x5a]),
                Exchange::Read(vec![1]),
                Exchange::Write(vec![0x60]),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(vec![8]),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(vec![0xd6]),
                Exchange::Write(vec![0x0c]),
                Exchange::Write(vec![2]),
                Exchange::Write(512u64.to_be_bytes().to_vec()),
                Exchange::Write(512u64.to_be_bytes().to_vec()),
                Exchange::Read(vec![0x5a]),
                Exchange::Write(0x100000u32.to_be_bytes().to_vec()),
                Exchange::Read(data.clone()),
                Exchange::Read(checksum.to_be_bytes().to_vec()),
                Exchange::Write(vec![0x5a]),
            ]
            .into(),
        );
        let mut sink = Collect(vec![]);
        pollster::block_on(read_region(&mut replay, 8, 1024, 512, 512, &mut sink)).unwrap();
        assert_eq!(sink.0, data);
        assert!(replay.0.is_empty());
    }

    #[test]
    fn physical_regions_do_not_alias_the_continuous_boot1_prefix() {
        let geometry = Geometry {
            boot1: 0x400000,
            boot2: 0x400000,
            rpmb: 0x80000,
            user: 0x1d2000000,
        };
        // Recorded Y2 reads at address zero returned BOOT1 even with selector
        // 2. BOOT2 and USER must therefore have explicit
        // continuous-view prefixes.
        for (partition, physical, expected) in [
            (1, 0, 0),
            (2, 0, 0x400000),
            (8, 0, 0x880000),
            (8, 0xb80000, 0x1400000),
            (8, 0x5180000, 0x5a00000),
            (8, 0x1d1fffe00, 0x1d287fe00),
        ] {
            assert_eq!(
                hardware_read_address(&geometry, partition, physical, 512).unwrap(),
                expected
            );
        }
        for (partition, address, length) in [
            (3, 0, 512),
            (1, 0x400000, 512),
            (2, 0x400000, 512),
            (8, 0x1d2000000, 512),
            (8, u64::MAX - 511, 1024),
            (8, 1, 512),
            (8, 0, 513),
            (8, 0, 0),
        ] {
            let mut replay = Replay(VecDeque::new());
            let mut sink = Collect(vec![]);
            assert!(
                pollster::block_on(read_hardware_region(
                    &mut replay,
                    &geometry,
                    partition,
                    address,
                    length,
                    &mut sink,
                ))
                .is_err()
            );
            assert!(replay.0.is_empty());
        }
    }

    #[test]
    fn rejects_a_range_past_the_reported_capacity_before_usb_io() {
        let mut replay = Replay(VecDeque::new());
        let mut sink = Collect(vec![]);
        assert!(
            pollster::block_on(read_region(&mut replay, 8, 1024, 512, 1024, &mut sink)).is_err()
        );
        assert!(replay.0.is_empty());
    }

    #[test]
    fn writes_an_addressed_emmc_region_with_da_checksums() {
        let data: Vec<_> = (0..1024).map(|n| n as u8).collect();
        let checksum = data
            .iter()
            .fold(0u16, |sum, byte| sum.wrapping_add(u16::from(*byte)));
        let mut exchanges = vec![
            Exchange::Write(vec![0x72]),
            Exchange::Read(vec![0x5a]),
            Exchange::Read(vec![1]),
            Exchange::Write(vec![0x62]),
            Exchange::Write(vec![2]),
            Exchange::Write(vec![8]),
            Exchange::Write(512u64.to_be_bytes().to_vec()),
            Exchange::Write(1024u64.to_be_bytes().to_vec()),
            Exchange::Write(0x100000u32.to_be_bytes().to_vec()),
            Exchange::Read(vec![0x5a]),
            Exchange::Write(vec![0x5a]),
            Exchange::Write(data.clone()),
            Exchange::Write(checksum.to_be_bytes().to_vec()),
            Exchange::Read(vec![0x69]),
        ];
        let mut replay = Replay(exchanges.drain(..).collect());
        let mut source = Bytes([vec![0; 512], data].concat());
        let mut progress = Progress(vec![]);
        pollster::block_on(write_region(
            &mut replay,
            WriteRegion {
                partition: 8,
                capacity: 4096,
                address: 512,
                length: 1024,
                source_offset: 512,
            },
            &mut source,
            &mut progress,
        ))
        .unwrap();
        assert_eq!(progress.0, vec![(1024, 1024)]);
        assert!(replay.0.is_empty());
    }

    #[test]
    fn rejects_an_invalid_write_before_reading_source_or_usb() {
        let mut replay = Replay(VecDeque::new());
        let mut source = Bytes(vec![]);
        let mut progress = Progress(vec![]);
        assert!(
            pollster::block_on(write_region(
                &mut replay,
                WriteRegion {
                    partition: 8,
                    capacity: 1024,
                    address: 512,
                    length: 1024,
                    source_offset: 0,
                },
                &mut source,
                &mut progress,
            ))
            .is_err()
        );
        assert!(progress.0.is_empty());
        assert!(replay.0.is_empty());
    }
    #[test]
    fn ram_boot_stops_at_upload_and_handles_empty_remainder() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../platform/firmware/DA.img"
        ))
        .unwrap();
        let agent = Agent::parse(&bytes, &chip()).unwrap();
        let fixture: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../tests/fixtures/spft-da-startup.json")).unwrap();
        for size in [4096, 4352] {
            let payload = vec![0x42; size];
            let mut script = VecDeque::new();
            for v in &fixture {
                if v["write"] == serde_json::json!([128, 0, 0, 0]) {
                    break;
                }
                if let Some(offset) = v["write_file"].as_u64() {
                    let o = offset as usize;
                    script.push_back(Exchange::Write(
                        bytes[o..o + v["length"].as_u64().unwrap() as usize].to_vec(),
                    ));
                } else {
                    let key = if v.get("write").is_some() {
                        "write"
                    } else {
                        "read"
                    };
                    let data = v[key]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|n| n.as_u64().unwrap() as u8)
                        .collect();
                    script.push_back(if key == "write" {
                        Exchange::Write(data)
                    } else {
                        Exchange::Read(data)
                    });
                }
            }
            script.push_back(Exchange::Write(0x80000000u32.to_be_bytes().to_vec()));
            script.push_back(Exchange::Write((size as u32).to_be_bytes().to_vec()));
            script.push_back(Exchange::Write(4096u32.to_be_bytes().to_vec()));
            script.push_back(Exchange::Read(vec![0x5a]));
            for chunk in payload.chunks(4096) {
                script.push_back(Exchange::Write(chunk.to_vec()));
                script.push_back(Exchange::Read(vec![0x5a]));
            }
            if size % 4096 == 0 {
                script.push_back(Exchange::Read(vec![0x5a]));
            }
            let mut replay = Replay(script);
            pollster::block_on(boot_ram(&mut replay, &agent, None, &payload)).unwrap();
            assert!(replay.0.is_empty());
        }
        let mut untouched = Replay(VecDeque::new());
        assert!(pollster::block_on(boot_ram(&mut untouched, &agent, None, &[0; 4])).is_err());
    }

    #[test]
    fn initializes_against_recorded_spft_exchange() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../platform/firmware/DA.img"
        ))
        .unwrap();
        let agent = Agent::parse(&bytes, &chip()).unwrap();
        assert_eq!(agent.first.bytes.len(), 52380);
        assert_eq!(agent.second.bytes.len(), 165564);
        let fixture: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../tests/fixtures/spft-da-startup.json")).unwrap();
        let mut replay = Replay(
            fixture
                .iter()
                .map(|v| {
                    if let Some(offset) = v["write_file"].as_u64() {
                        let o = offset as usize;
                        return Exchange::Write(
                            bytes[o..o + v["length"].as_u64().unwrap() as usize].to_vec(),
                        );
                    }
                    let key = if v.get("write").is_some() {
                        "write"
                    } else {
                        "read"
                    };
                    let data = v[key]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|n| n.as_u64().unwrap() as u8)
                        .collect();
                    if key == "write" {
                        Exchange::Write(data)
                    } else {
                        Exchange::Read(data)
                    }
                })
                .collect(),
        );
        let geo = pollster::block_on(initialize(&mut replay, &agent)).unwrap();
        assert_eq!(geo.user, 0x1d2000000);
        assert_eq!(geo.boot1, 0x400000);
        assert_eq!(geo.boot2, 0x400000);
        assert!(replay.0.is_empty());
        assert!(Agent::parse(&bytes[..100], &chip()).is_err());
        assert!(Agent::parse(&bytes[..700000], &chip()).is_err());
    }
}
