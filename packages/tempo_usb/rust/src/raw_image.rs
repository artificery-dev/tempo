//! Offline raw-image validation. This module never creates USB write tickets.
use serde::Serialize;

use crate::Result;
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    Bootimg,
    Logo,
    Boot1,
}
impl Target {
    pub fn parse(name: &str) -> Result<Self> {
        match name.to_ascii_uppercase().as_str() {
            "BOOTIMG" => Ok(Self::Bootimg),
            "LOGO" => Ok(Self::Logo),
            "BOOT1" => Ok(Self::Boot1),
            _ => Err("Raw image target must be BOOTIMG, LOGO or BOOT1".into()),
        }
    }
    pub fn capacity(self) -> usize {
        match self {
            Self::Bootimg => 0x1000000,
            Self::Logo => 0x300000,
            Self::Boot1 => 0x400000,
        }
    }
}
#[derive(Debug, Serialize)]
pub struct Info {
    pub target: Target,
    pub size: usize,
    pub padded_size: usize,
    pub description: String,
}
fn word(bytes: &[u8], offset: usize) -> Result<u64> {
    Ok(u32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or("Truncated image header")?
            .try_into()
            .unwrap(),
    ) as u64)
}
pub fn inspect(target: Target, bytes: &[u8]) -> Result<Info> {
    let padded = bytes
        .len()
        .checked_add(511)
        .ok_or("Raw image size overflow")?
        / 512
        * 512;
    if bytes.is_empty() || padded > target.capacity() {
        return Err("Raw image does not fit the target partition".into());
    }
    let description = match target {
        Target::Bootimg => {
            if bytes.get(..8) != Some(b"ANDROID!") {
                return Err("BOOTIMG needs an ANDROID! image".into());
            }
            let page = word(bytes, 36)?;
            if !matches!(page, 2048 | 4096 | 8192 | 16384) {
                return Err("Implausible Android boot page size".into());
            }
            let kernel = word(bytes, 8)?;
            let ramdisk = word(bytes, 16)?;
            let second = word(bytes, 24)?;
            let dt = word(bytes, 40)?;
            let described = page
                * (1 + kernel.div_ceil(page)
                    + ramdisk.div_ceil(page)
                    + second.div_ceil(page)
                    + dt.div_ceil(page));
            if kernel == 0 || described > bytes.len() as u64 {
                return Err("Android boot header describes missing payload bytes".into());
            }
            format!("Android v0 boot image: kernel {kernel}, ramdisk {ramdisk}, page {page}")
        }
        Target::Logo => {
            if bytes.get(..4) != Some(&[0x88, 0x16, 0x88, 0x58])
                || bytes.get(8..40).is_none_or(|name| {
                    name.get(..4) != Some(b"LOGO") || name[4..].iter().any(|byte| *byte != 0)
                })
            {
                return Err("LOGO needs a MediaTek LOGO image header".into());
            }
            let body = word(bytes, 4)?;
            let count = word(bytes, 512)?;
            let total = word(bytes, 516)?;
            if body + 512 != bytes.len() as u64
                || body <= 8
                || count == 0
                || count >= 256
                || total != body
            {
                return Err("Inconsistent LOGO body length or block count".into());
            }
            let mut previous = 8 + count * 4;
            for i in 0..count as usize {
                let offset = word(bytes, 520 + i * 4)?;
                if offset < previous || offset >= body {
                    return Err("Invalid LOGO block offsets".into());
                }
                if i > 0 && offset == previous {
                    return Err("Duplicate LOGO block offset".into());
                }
                previous = offset;
            }
            format!("MediaTek LOGO: {count} blocks, {body} body bytes")
        }
        Target::Boot1 => {
            if bytes.len() != 0x400000 {
                return Err("BOOT1 input must cover the complete 4 MiB hardware region".into());
            }
            let write = crate::firmware::PlannedWrite {
                image: 0,
                mapping: 0,
                region: crate::firmware::Region::Boot1,
                source_offset: 0,
                target_offset: 0,
                length: 0x400000,
            };
            crate::firmware::validate_preloader(bytes, &write)?;
            "Complete EMMC_BOOT/BRLYT/GFH wrapped preloader".into()
        }
    };
    Ok(Info {
        target,
        size: bytes.len(),
        padded_size: padded,
        description,
    })
}
#[cfg(not(target_arch = "wasm32"))]
pub fn inspect_file(target: Target, path: &std::path::Path) -> Result<Info> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.take(target.capacity() as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    inspect(target, &bytes)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn boot_requires_plausible_complete_payload() {
        let mut bytes = vec![0; 4096];
        bytes[..8].copy_from_slice(b"ANDROID!");
        bytes[8..12].copy_from_slice(&1u32.to_le_bytes());
        bytes[36..40].copy_from_slice(&2048u32.to_le_bytes());
        assert!(inspect(Target::Bootimg, &bytes).is_ok());
        assert!(inspect(Target::Bootimg, &bytes[..2048]).is_err());
        bytes[36..40].fill(0);
        assert!(inspect(Target::Bootimg, &bytes).is_err());
    }
    #[test]
    fn logo_requires_ordered_block_table_and_exact_size() {
        let mut bytes = vec![0; 544];
        bytes[..4].copy_from_slice(&[0x88, 0x16, 0x88, 0x58]);
        bytes[4..8].copy_from_slice(&32u32.to_le_bytes());
        bytes[8..12].copy_from_slice(b"LOGO");
        bytes[512..516].copy_from_slice(&2u32.to_le_bytes());
        bytes[516..520].copy_from_slice(&32u32.to_le_bytes());
        bytes[520..524].copy_from_slice(&16u32.to_le_bytes());
        bytes[524..528].copy_from_slice(&24u32.to_le_bytes());
        assert_eq!(inspect(Target::Logo, &bytes).unwrap().padded_size, 1024);
        bytes[524..528].copy_from_slice(&16u32.to_le_bytes());
        assert!(inspect(Target::Logo, &bytes).is_err());
    }
    #[test]
    fn arbitrary_raw_targets_and_unwrapped_boot1_are_refused() {
        assert!(Target::parse("UBOOT").is_err());
        assert!(inspect(Target::Boot1, &vec![0; 0x400000]).is_err());
    }
    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn stock_logo_passes_strict_validation() {
        let bytes = include_bytes!("../../../../platform/firmware/stock/logo.bin");
        assert!(inspect(Target::Logo, bytes).is_ok());
    }
}
