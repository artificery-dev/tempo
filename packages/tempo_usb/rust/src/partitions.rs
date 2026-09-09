//! Read-only vendor partition discovery. Never use an unobserved scatter base.
use serde::Serialize;

use crate::{Result, Transport, da};

#[derive(Clone, Debug, Serialize)]
pub struct Partition {
    pub name: String,
    pub physical: u64,
    pub size: u64,
}

pub fn scatter(text: &str) -> Result<Vec<Partition>> {
    let mut rows = Vec::<std::collections::BTreeMap<&str, &str>>::new();
    for line in text.lines().map(str::trim) {
        if line.starts_with("- partition_index:") {
            rows.push(Default::default());
        }
        if let Some((key, value)) = line.split_once(':')
            && let Some(row) = rows.last_mut()
        {
            row.insert(key.trim(), value.trim());
        }
    }
    let mut parts = Vec::new();
    let mut names = std::collections::BTreeSet::new();
    for row in rows {
        let get = |key| {
            row.get(key)
                .copied()
                .ok_or_else(|| format!("Scatter missing {key}"))
        };
        if get("region")? != "EMMC_USER" {
            continue;
        }
        let number = |key| -> Result<u64> {
            let raw = get(key)?;
            if let Some(hex) = raw.strip_prefix("0x") {
                u64::from_str_radix(hex, 16)
            } else {
                raw.parse()
            }
            .map_err(|_| format!("Invalid scatter {key}"))
        };
        let physical = number("physical_start_addr")?;
        if physical >= 0xf0000000 {
            continue;
        }
        let linear = number("linear_start_addr")?;
        if linear.checked_sub(physical) != Some(0x1400000) {
            return Err("Unexpected scatter address convention".into());
        }
        let name = get("partition_name")?.to_owned();
        if !names.insert(name.clone()) {
            return Err("Duplicate scatter partition".into());
        }
        parts.push(Partition {
            name,
            physical,
            size: number("partition_size")?,
        });
    }
    if !["MBR", "EBR1", "BOOTIMG", "LOGO", "FAT"]
        .iter()
        .all(|name| names.contains(*name))
    {
        return Err("Incomplete Y2 scatter".into());
    }
    let mut end = 0;
    for part in &parts {
        if part.physical != end {
            return Err("Scatter partitions overlap or have a gap".into());
        }
        end = part
            .physical
            .checked_add(part.size)
            .ok_or("Scatter overflow")?;
    }
    Ok(parts)
}

pub fn vendor_scatter() -> Result<Vec<Partition>> {
    scatter(include_str!(
        "../../../../platform/firmware/stock/MT6582_Android_scatter.txt"
    ))
}

fn signature(bytes: &[u8]) -> bool {
    bytes.len() == 512 && bytes[510..] == [0x55, 0xaa]
}
fn mbr(bytes: &[u8]) -> bool {
    signature(bytes)
        && bytes[446..510]
            .as_chunks::<16>()
            .0
            .iter()
            .all(|entry| matches!(entry[0], 0 | 0x80))
        && bytes[446..510]
            .as_chunks::<16>()
            .0
            .iter()
            .any(|entry| entry[4] != 0 && u32::from_le_bytes(entry[8..12].try_into().unwrap()) != 0)
}
#[derive(Debug, Serialize)]
pub struct Finding {
    pub address: u64,
    pub mbr: bool,
    pub ebr: bool,
}
#[derive(Debug, Serialize)]
pub struct Anchor {
    pub base: u64,
    pub findings: Vec<Finding>,
}
struct Sector(Vec<u8>);
impl da::BackupSink for Sector {
    async fn chunk(&mut self, bytes: &[u8], _: u64, _: u64) -> Result<()> {
        if self.0.len() + bytes.len() > 512 {
            return Err("Oversized anchor read".into());
        }
        self.0.extend_from_slice(bytes);
        Ok(())
    }
}

/// Probe the three historical DA numbering conventions, requiring MBR + EBR1.
/// This read command exposes a continuous image, so capacity includes boot
/// areas.
pub async fn locate(
    port: &mut impl Transport,
    geometry: &da::Geometry,
    parts: &[Partition],
) -> Result<Anchor> {
    if !geometry.is_y2() {
        return Err("Partition lookup requires verified Y2 geometry".into());
    }
    let boot = parts
        .iter()
        .find(|p| p.name == "BOOTIMG")
        .ok_or("Missing BOOTIMG")?;
    let shift = 0x2900000u64
        .checked_sub(boot.physical)
        .ok_or("Invalid BOOTIMG address")?;
    if shift % 0x20000 != 0 || boot.size != 0x1000000 {
        return Err("Scatter does not match Y2 BOOTIMG".into());
    }
    let ebr = parts
        .iter()
        .find(|p| p.name == "EBR1")
        .ok_or("Missing EBR1")?
        .physical;
    let capacity = geometry.image_size()?;
    let mut findings = Vec::new();
    for address in [0, shift, 0x1400000]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>()
    {
        let mut first = Sector(Vec::new());
        let mut second = Sector(Vec::new());
        da::read_region(port, 8, capacity, address, 512, &mut first).await?;
        da::read_region(
            port,
            8,
            capacity,
            address.checked_add(ebr).ok_or("Anchor overflow")?,
            512,
            &mut second,
        )
        .await?;
        findings.push(Finding {
            address,
            mbr: mbr(&first.0),
            ebr: signature(&second.0),
        });
    }
    resolve(findings)
}
fn resolve(findings: Vec<Finding>) -> Result<Anchor> {
    let hits: Vec<_> = findings
        .iter()
        .filter(|f| f.mbr && f.ebr)
        .map(|f| f.address)
        .collect();
    if hits.len() != 1 {
        return Err(format!(
            "Cannot anchor partition layout: expected one MBR + EBR1, found {} ({})",
            hits.len(),
            serde_json::to_string(&findings).unwrap()
        ));
    }
    Ok(Anchor {
        base: hits[0],
        findings,
    })
}

pub fn range(
    name: &str,
    anchor: &Anchor,
    parts: &[Partition],
    capacity: u64,
) -> Result<(u64, u64)> {
    let part = parts
        .iter()
        .find(|p| p.name.eq_ignore_ascii_case(name))
        .ok_or("Unknown USER partition")?;
    let address = anchor
        .base
        .checked_add(part.physical)
        .ok_or("Partition overflow")?;
    let size = if part.size == 0 && part.name == "FAT" {
        capacity
            .checked_sub(address)
            .ok_or("FAT starts outside device")?
    } else {
        part.size
    };
    if size == 0 || address.checked_add(size).is_none_or(|end| end > capacity) {
        return Err("Partition is outside the verified device".into());
    }
    Ok((address, size))
}

pub async fn inspect_or_fetch(
    port: &mut impl Transport,
    geometry: &da::Geometry,
    requested: Option<(&str, &std::path::Path)>,
) -> Result<serde_json::Value> {
    use std::io::Write;

    use sha2::{Digest, Sha256};
    if !geometry.is_y2() {
        return Err("Partition operation requires exact Y2 geometry".into());
    }
    let parts = vendor_scatter()?;
    let hardware = requested
        .map(|(name, _)| name.eq_ignore_ascii_case("boot1") || name.eq_ignore_ascii_case("boot2"))
        .unwrap_or(false);
    let anchor = if hardware {
        None
    } else {
        Some(locate(port, geometry, &parts).await?)
    };
    let Some((name, path)) = requested else {
        return Ok(serde_json::json!({"anchor":anchor,"partitions":parts}));
    };
    let (partition, capacity, address, size) = if hardware {
        let (number, size) = if name.eq_ignore_ascii_case("boot1") {
            (1, geometry.boot1)
        } else {
            (2, geometry.boot2)
        };
        (
            8,
            geometry.image_size()?,
            da::hardware_read_address(geometry, number, 0, size)?,
            size,
        )
    } else {
        let capacity = geometry.image_size()?;
        let (address, size) = range(name, anchor.as_ref().unwrap(), &parts, capacity)?;
        (8, capacity, address, size)
    };
    if path.exists() {
        return Err("Partition output already exists".into());
    }
    let temporary = path.with_file_name(format!(
        "{}.partial",
        path.file_name()
            .ok_or("Missing output filename")?
            .to_string_lossy()
    ));
    struct Output {
        file: std::fs::File,
        hash: Sha256,
        written: u64,
    }
    impl da::BackupSink for Output {
        async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<()> {
            self.file.write_all(bytes).map_err(|e| e.to_string())?;
            self.hash.update(bytes);
            self.written += bytes.len() as u64;
            println!(
                "{}",
                serde_json::json!({"event":"progress","completed":completed,"total":total})
            );
            Ok(())
        }
    }
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    let _cleanup = Cleanup(temporary.clone());
    let mut output = Output {
        file,
        hash: Sha256::new(),
        written: 0,
    };
    let read = da::read_region(port, partition, capacity, address, size, &mut output).await;
    if let Err(error) = read {
        drop(output);
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    if output.written != size {
        drop(output);
        let _ = std::fs::remove_file(&temporary);
        return Err("Partition read length mismatch".into());
    }
    output.file.sync_all().map_err(|e| e.to_string())?;
    let digest = output
        .hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    drop(output.file);
    // Hard-link publish cannot overwrite a file created during the read.
    std::fs::hard_link(&temporary, path).map_err(|e| e.to_string())?;
    std::fs::remove_file(&temporary).map_err(|e| e.to_string())?;
    Ok(
        serde_json::json!({"partition":name,"address":address,"bytes":size,"sha256":digest,"path":path,"anchor":anchor,"storage_written":false}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn vendor_is_contiguous_and_ranges_are_bounded() {
        let parts = vendor_scatter().unwrap();
        let anchor = Anchor {
            base: 0x1400000,
            findings: vec![],
        };
        let (address, size) = range("bootimg", &anchor, &parts, 0x1d2880000).unwrap();
        assert_eq!(address, 0x3180000);
        assert_eq!(size, 0x1000000);
        assert!(range("RPMB", &anchor, &parts, 0x1d2880000).is_err());
        assert!(range("BOOTIMG", &anchor, &parts, 512).is_err());
    }
    #[test]
    fn anchor_requires_exactly_one_two_sector_match() {
        assert!(resolve(vec![]).is_err());
        assert!(
            resolve(vec![Finding {
                address: 0,
                mbr: true,
                ebr: false
            }])
            .is_err()
        );
        assert!(
            resolve(vec![
                Finding {
                    address: 0,
                    mbr: true,
                    ebr: true
                },
                Finding {
                    address: 1,
                    mbr: true,
                    ebr: true
                }
            ])
            .is_err()
        );
        assert_eq!(
            resolve(vec![Finding {
                address: 7,
                mbr: true,
                ebr: true
            }])
            .unwrap()
            .base,
            7
        );
    }
    #[test]
    fn signature_alone_does_not_anchor() {
        let mut bytes = [0u8; 512];
        bytes[510..].copy_from_slice(&[0x55, 0xaa]);
        assert!(!mbr(&bytes));
        bytes[450] = 0x83;
        bytes[454] = 1;
        assert!(mbr(&bytes));
        bytes[446] = 1;
        assert!(!mbr(&bytes));
    }
    #[test]
    fn rejects_wrong_scatter_convention() {
        let source = include_str!("../../../../platform/firmware/stock/MT6582_Android_scatter.txt");
        assert!(
            scatter(&source.replacen(
                "linear_start_addr: 0x1400000",
                "linear_start_addr: 0x1400001",
                1
            ))
            .is_err()
        );
    }
    #[test]
    fn observes_both_sectors_at_all_three_candidates_through_read_protocol() {
        use std::collections::VecDeque;
        enum Step {
            Write(Vec<u8>),
            Read(Vec<u8>),
        }
        struct Replay(VecDeque<Step>);
        impl Transport for Replay {
            async fn write(&mut self, bytes: &[u8]) -> Result<()> {
                match self.0.pop_front() {
                    Some(Step::Write(expected)) if expected == bytes => Ok(()),
                    _ => Err(format!("Unexpected write {bytes:?}")),
                }
            }
            async fn read(&mut self, _: usize) -> Result<Vec<u8>> {
                match self.0.pop_front() {
                    Some(Step::Read(bytes)) => Ok(bytes),
                    _ => Err("Unexpected read".into()),
                }
            }
            async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
                Err("Unexpected control".into())
            }
        }
        let parts = vendor_scatter().unwrap();
        let ebr = parts.iter().find(|p| p.name == "EBR1").unwrap().physical;
        let mut steps = VecDeque::new();
        for base in [0, 0xb80000, 0x1400000u64] {
            for offset in [0, ebr] {
                let mut bytes = vec![0u8; 512];
                if base == 0x1400000 {
                    bytes[510..].copy_from_slice(&[0x55, 0xaa]);
                    if offset == 0 {
                        bytes[450] = 0x83;
                        bytes[454] = 1;
                    }
                }
                let checksum = bytes
                    .iter()
                    .fold(0u16, |sum, b| sum.wrapping_add(u16::from(*b)));
                steps.extend([
                    Step::Write(vec![0x72]),
                    Step::Read(vec![0x5a]),
                    Step::Read(vec![1]),
                    Step::Write(vec![0x60]),
                    Step::Read(vec![0x5a]),
                    Step::Write(vec![8]),
                    Step::Read(vec![0x5a]),
                    Step::Write(vec![0xd6]),
                    Step::Write(vec![0x0c]),
                    Step::Write(vec![2]),
                    Step::Write((base + offset).to_be_bytes().to_vec()),
                    Step::Write(512u64.to_be_bytes().to_vec()),
                    Step::Read(vec![0x5a]),
                    Step::Write(0x100000u32.to_be_bytes().to_vec()),
                    Step::Read(bytes),
                    Step::Read(checksum.to_be_bytes().to_vec()),
                    Step::Write(vec![0x5a]),
                ]);
            }
        }
        let mut port = Replay(steps);
        let geometry = da::Geometry {
            user: 0x1d2000000,
            boot1: 0x400000,
            boot2: 0x400000,
            rpmb: 0x80000,
        };
        let found = pollster::block_on(locate(&mut port, &geometry, &parts)).unwrap();
        assert_eq!(found.base, 0x1400000);
        assert_eq!(found.findings.len(), 3);
        assert!(port.0.is_empty());
    }
}
