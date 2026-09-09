//! Explicit Y2 preloader DRAM configuration for the vendor legacy DA.
use crate::{Result, Transport, da::expect, read_exact};

pub struct Emi {
    pub version: u32,
    pub bytes: Vec<u8>,
}
impl Emi {
    pub fn parse(input: &[u8]) -> Result<Self> {
        if input.len() > 4 * 1024 * 1024 {
            return Err("Preloader input exceeds the Y2 BOOT1 size".into());
        }
        fn find(bytes: &[u8], needle: &[u8]) -> Result<usize> {
            bytes
                .windows(needle.len())
                .position(|v| v == needle)
                .ok_or_else(|| "Missing preloader EMI metadata".into())
        }
        fn word(bytes: &[u8], offset: usize) -> Result<usize> {
            Ok(u32::from_le_bytes(
                bytes
                    .get(offset..offset + 4)
                    .ok_or("Truncated preloader")?
                    .try_into()
                    .unwrap(),
            ) as usize)
        }
        let start = find(input, b"MMM\x01\x38\x00\x00\x00")?;
        let image = &input[start..];
        let length = word(image, 0x20)?;
        let signature = word(image, 0x2c)?;
        let end = length
            .checked_sub(signature)
            .ok_or("Invalid preloader signature size")?;
        let mut body = image.get(..end).ok_or("Preloader length exceeds input")?;
        let mut size = word(
            body,
            body.len().checked_sub(4).ok_or("Truncated preloader")?,
        )?;
        if size == 0 {
            body = body
                .get(..body.len().checked_sub(0x800).ok_or("Missing EMI trailer")?)
                .ok_or("Missing EMI trailer")?;
            size = word(
                body,
                body.len().checked_sub(4).ok_or("Truncated EMI trailer")?,
            )?;
        }
        if size == 0 || size > 1024 * 1024 {
            return Err("Invalid EMI table size".into());
        }
        let table = body
            .get(
                body.len()
                    .checked_sub(size + 4)
                    .ok_or("EMI table exceeds preloader")?..body.len() - 4,
            )
            .ok_or("Invalid EMI range")?;
        let marker = b"MTK_BLOADER_INFO_v";
        let version_at = find(table, marker)? + marker.len();
        let version = std::str::from_utf8(
            table
                .get(version_at..version_at + 2)
                .ok_or("Missing EMI version")?,
        )
        .map_err(|_| "Invalid EMI version")?
        .trim_end_matches('\0')
        .parse::<u32>()
        .map_err(|_| "Invalid EMI version")?;
        if version != 12 {
            return Err(format!("Unsupported Y2 EMI version {version}; expected 12"));
        }
        let binary = find(table, b"MTK_BIN")? + 12;
        let bytes = table.get(binary..).ok_or("Truncated EMI binary")?.to_vec();
        if bytes.len() < 8 {
            return Err("EMI binary is too short".into());
        }
        Ok(Self { version, bytes })
    }
}

pub async fn initialize_dram(
    port: &mut impl Transport,
    status: [u8; 4],
    emi: Option<&Emi>,
) -> Result<()> {
    if status == [0; 4] {
        return Ok(());
    }
    if u32::from_be_bytes(status) != 0xbc3 {
        return Err(format!(
            "DRAM initialization failed: {:x}",
            u32::from_be_bytes(status)
        ));
    }
    let emi =
        emi.ok_or("BROM requires the device's own preloader EMI data; supply --preloader FILE")?;
    if emi.version != 12 {
        return Err("Unsupported legacy EMI version".into());
    }
    let _request = read_exact(port, 4).await?;
    let _dram_id = read_exact(port, 16).await?;
    expect(port, &0xbc4u32.to_be_bytes(), "DRAM configuration request").await?;
    let count = u16::from_be_bytes(read_exact(port, 2).await?.try_into().unwrap()) as usize;
    if count > 32 {
        return Err("Invalid DRAM NAND identifier count".into());
    }
    let _ids = read_exact(port, count * 2).await?;
    port.write(&[0xe8]).await?;
    port.write(&emi.version.to_be_bytes()).await?;
    expect(port, &[0x5a], "EMI version acceptance").await?;
    let length = u32::from_be_bytes(read_exact(port, 4).await?.try_into().unwrap()) as usize;
    if !(4..=emi.bytes.len()).contains(&length) {
        return Err("DA requested an invalid EMI length".into());
    }
    let mut bytes = emi.bytes[..length].to_vec();
    bytes[..4].copy_from_slice(&0x100u32.to_be_bytes());
    port.write(&[0x5a]).await?;
    port.write(&bytes).await?;
    let _checksum = read_exact(port, 2).await?;
    port.write(&[0x5a]).await?;
    port.write(&0x80000001u32.to_be_bytes()).await?;
    expect(port, &[0; 4], "EMI DRAM setup").await?;
    let memory = read_exact(port, 10).await?;
    let size = u64::from_be_bytes(memory[2..].try_into().unwrap());
    if memory[0] != 2 || size == 0 || size > 4 * 1024 * 1024 * 1024 {
        return Err("DA reported invalid external DRAM".into());
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_preloader_never_produces_emi() {
        for input in [&[][..], &[0; 64][..], b"MMM\x01\x38\x00\x00\x00".as_slice()] {
            assert!(Emi::parse(input).is_err());
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn accepts_stock_y2_v12_and_rejects_truncation() {
        let input =
            include_bytes!("../../../../platform/firmware/stock/preloader_eastaeon82_wet_kk.bin");
        let emi = Emi::parse(input).unwrap();
        assert_eq!(emi.version, 12);
        assert_eq!(emi.bytes.len(), 2068);
        assert!(Emi::parse(&input[..input.len() / 2]).is_err());
    }
    enum Step {
        Write(Vec<u8>),
        Read(Vec<u8>),
    }
    struct Replay(std::collections::VecDeque<Step>);
    impl Transport for Replay {
        async fn write(&mut self, bytes: &[u8]) -> Result<()> {
            match self.0.pop_front() {
                Some(Step::Write(expected)) if expected == bytes => Ok(()),
                _ => Err(format!("Unexpected EMI write {bytes:?}")),
            }
        }
        async fn read(&mut self, _: usize) -> Result<Vec<u8>> {
            match self.0.pop_front() {
                Some(Step::Read(bytes)) => Ok(bytes),
                _ => Err("Unexpected EMI read".into()),
            }
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Err("Unexpected EMI control".into())
        }
    }
    #[test]
    fn brom_without_explicit_emi_refuses_before_ram_upload() {
        let mut port = Replay(Default::default());
        assert!(
            pollster::block_on(initialize_dram(&mut port, 0xbc3u32.to_be_bytes(), None))
                .unwrap_err()
                .contains("--preloader")
        );
        assert!(port.0.is_empty());
    }
    #[test]
    fn replays_v12_dram_configuration_and_bounds_requested_length() {
        let emi = Emi {
            version: 12,
            bytes: vec![0, 0, 0, 0, 1, 2, 3, 4],
        };
        fn prefix() -> std::collections::VecDeque<Step> {
            [
                Step::Read(vec![0; 4]),
                Step::Read(vec![0; 16]),
                Step::Read(0xbc4u32.to_be_bytes().to_vec()),
                Step::Read(vec![0, 0]),
                Step::Write(vec![0xe8]),
                Step::Write(12u32.to_be_bytes().to_vec()),
                Step::Read(vec![0x5a]),
            ]
            .into()
        }
        let mut steps = prefix();
        steps.extend([
            Step::Read(8u32.to_be_bytes().to_vec()),
            Step::Write(vec![0x5a]),
            Step::Write(vec![0, 0, 1, 0, 1, 2, 3, 4]),
            Step::Read(vec![0, 10]),
            Step::Write(vec![0x5a]),
            Step::Write(0x80000001u32.to_be_bytes().to_vec()),
            Step::Read(vec![0; 4]),
            Step::Read(vec![2, 0, 0, 0, 0, 0, 0x20, 0, 0, 0]),
        ]);
        let mut port = Replay(steps);
        pollster::block_on(initialize_dram(
            &mut port,
            0xbc3u32.to_be_bytes(),
            Some(&emi),
        ))
        .unwrap();
        assert!(port.0.is_empty());
        let mut steps = prefix();
        steps.push_back(Step::Read(1024u32.to_be_bytes().to_vec()));
        let mut port = Replay(steps);
        assert!(
            pollster::block_on(initialize_dram(
                &mut port,
                0xbc3u32.to_be_bytes(),
                Some(&emi)
            ))
            .is_err()
        );
        assert!(port.0.is_empty());
    }
}
