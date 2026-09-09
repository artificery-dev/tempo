//! Shared MediaTek connection probe and experimental read-only DA backup
//! engine. DA loading writes RAM; storage erase/write commands are not exposed.
use serde::{Deserialize, Serialize};

#[cfg(not(target_arch = "wasm32"))]
pub mod backup_resume;
#[cfg(not(target_arch = "wasm32"))]
pub mod native;
#[cfg(not(target_arch = "wasm32"))]
pub mod package;
#[cfg(not(target_arch = "wasm32"))]
pub mod partitions;
#[cfg(not(target_arch = "wasm32"))]
pub mod recovery;
#[cfg(not(target_arch = "wasm32"))]
pub mod recovery_workflows;
#[cfg(not(target_arch = "wasm32"))]
pub mod restore;
#[cfg(not(target_arch = "wasm32"))]
pub mod sparse_image;
#[cfg(not(target_arch = "wasm32"))]
pub mod spft;
#[cfg(target_arch = "wasm32")]
mod web;

pub mod da;
pub mod emi;
pub mod firmware;
pub mod raw_image;
#[cfg(not(target_arch = "wasm32"))]
pub mod raw_install;

pub type Result<T> = std::result::Result<T, String>;

pub fn is_candidate(vendor: u16, product: u16) -> bool {
    vendor == 0x0e8d && matches!(product, 0x2000 | 0x2001 | 0x0003)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Endpoint {
    pub address: u8,
    pub bulk: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Interface {
    pub number: u8,
    pub alternate: u8,
    pub class: u8,
    pub endpoints: Vec<Endpoint>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Layout {
    pub interface: u8,
    pub alternate: u8,
    pub input: u8,
    pub output: u8,
    pub control: Option<u8>,
}

/// Never guess endpoint numbers or silently choose among multiple data ports.
pub fn select_layout(interfaces: &[Interface]) -> Result<Layout> {
    let mut choices = Vec::new();
    for interface in interfaces {
        if !matches!(interface.class, 0x0a | 0xff) {
            continue;
        }
        let inputs: Vec<_> = interface
            .endpoints
            .iter()
            .filter(|e| e.bulk && e.address & 0x80 != 0)
            .collect();
        let outputs: Vec<_> = interface
            .endpoints
            .iter()
            .filter(|e| e.bulk && e.address & 0x80 == 0)
            .collect();
        if inputs.len() == 1 && outputs.len() == 1 {
            choices.push(Layout {
                interface: interface.number,
                alternate: interface.alternate,
                input: inputs[0].address,
                output: outputs[0].address,
                control: None,
            });
        }
    }
    if choices.len() != 1 {
        return Err(format!(
            "Expected one USB bulk data interface; found {}",
            choices.len()
        ));
    }
    let mut layout = choices.remove(0);
    let controls: Vec<_> = interfaces
        .iter()
        .filter(|i| i.class == 2 && i.alternate == 0)
        .collect();
    if controls.len() > 1 {
        return Err("Multiple CDC control interfaces; refusing to guess their association".into());
    }
    layout.control = controls.first().map(|i| i.number);
    Ok(layout)
}

#[allow(async_fn_in_trait)]
pub trait Transport {
    /// A complete bounded DA read command must finish before cancellation.
    fn begin_read_transaction(&mut self) -> Result<()> {
        Ok(())
    }
    /// `synchronized` means the final checksum ACK completed on the wire.
    fn finish_read_transaction(&mut self, _synchronized: bool) -> Result<()> {
        Ok(())
    }
    /// A bounded transfer. A timeout must end the session, not leave a read
    /// alive to consume bytes from the next attempt.
    async fn read(&mut self, length: usize) -> Result<Vec<u8>>;
    async fn write(&mut self, data: &[u8]) -> Result<()>;
    async fn control(&mut self, request: u8, value: u16, index: u16, data: &[u8]) -> Result<()>;
}

#[derive(Debug, Serialize)]
pub struct ProbeReport {
    pub hardware_code: u16,
    pub hardware_version: u16,
    pub hardware_subcode: u16,
    pub software_version: u16,
    pub compatible_chip: bool,
    pub y2_verified: bool,
    pub storage_written: bool,
}

async fn read_exact(port: &mut impl Transport, length: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(length);
    while bytes.len() < length {
        let next = port.read(length - bytes.len()).await?;
        if next.is_empty() || next.len() > length - bytes.len() {
            return Err("Invalid or empty USB response".into());
        }
        if bytes.is_empty() && next.len() == length {
            return Ok(next);
        }
        bytes.extend(next);
    }
    Ok(bytes)
}

// The startup listener polls every 20 ms and may consume both A0 bytes in
// one batch if we react immediately to a buffered READY. SPFT's successful
// capture spaces them by 23.865 ms. Leave one poll interval before retrying.
async fn wait_for_download_handler() -> Result<()> {
    #[cfg(not(target_arch = "wasm32"))]
    std::thread::sleep(std::time::Duration::from_millis(25));
    #[cfg(target_arch = "wasm32")]
    web::delay(25).await?;
    Ok(())
}

pub async fn probe(port: &mut impl Transport, layout: &Layout) -> Result<ProbeReport> {
    if let Some(control) = layout.control {
        // USB CDC: 921600 baud, one stop bit, no parity, eight data bits;
        // assert RTS. These are transport setup, not flash/register writes.
        port.control(0x20, 0, control.into(), &[0x00, 0x10, 0x0e, 0, 0, 0, 8])
            .await?;
        port.control(0x22, 2, control.into(), &[]).await?;
    }
    // The Y2 can queue repeated ASCII READY announcements before our first
    // sync byte. The first A0 enters the download handler; after READY,
    // retry A0 once to synchronize (SPFT capture, 2026-09-06 frames 191-213).
    // Consume queued banners without sending a retry for every character.
    let sequence = [0xa0, 0x0a, 0x50, 0x05];
    let mut position = 0;
    let mut banners = 0;
    for _ in 0..32 {
        port.write(&[sequence[position]]).await?;
        let echo = loop {
            let byte = read_exact(port, 1).await?[0];
            if position == 0 && byte == b'R' {
                if banners == 64 {
                    return Err(
                        "Preloader keeps announcing READY without answering synchronization".into(),
                    );
                }
                if read_exact(port, 4).await? != b"EADY" {
                    return Err("Unrecognized preloader startup announcement".into());
                }
                if banners == 0 {
                    wait_for_download_handler().await?;
                    port.write(&[0xa0]).await?;
                }
                banners += 1;
                continue;
            }
            break byte;
        };
        if echo == !sequence[position] {
            position += 1;
            if position == sequence.len() {
                break;
            }
        } else {
            position = usize::from(echo == !sequence[0]);
        }
    }
    if position != sequence.len() {
        return Err(
            "Preloader did not synchronize. Power off and reconnect for a fresh attempt.".into(),
        );
    }
    port.write(&[0xfd]).await?; // GET_HW_CODE, a read-only query.
    if read_exact(port, 1).await? != [0xfd] {
        return Err(
            "GET_HW_CODE echo mismatch; device may already be running a download agent".into(),
        );
    }
    let response = read_exact(port, 4).await?;
    let hardware_code = u16::from_be_bytes([response[0], response[1]]);
    if response[2..] != [0, 0] {
        return Err("GET_HW_CODE returned a nonzero status".into());
    }
    port.write(&[0xfc]).await?; // GET_HW_SW_VER, also read-only.
    if read_exact(port, 1).await? != [0xfc] {
        return Err("GET_HW_SW_VER echo mismatch".into());
    }
    let versions = read_exact(port, 8).await?;
    if versions[6..] != [0, 0] {
        return Err("GET_HW_SW_VER returned a nonzero status".into());
    }
    Ok(ProbeReport {
        hardware_code,
        hardware_version: u16::from_be_bytes([versions[2], versions[3]]),
        hardware_subcode: u16::from_be_bytes([versions[0], versions[1]]),
        software_version: u16::from_be_bytes([versions[4], versions[5]]),
        compatible_chip: hardware_code == 0x6582,
        // Chip ID alone does not identify a Y2. DA geometry and partition
        // verification belong to the next milestone.
        y2_verified: false,
        storage_written: false,
    })
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    struct Fake {
        reads: VecDeque<Vec<u8>>,
        writes: Vec<Vec<u8>>,
    }
    impl Transport for Fake {
        async fn read(&mut self, _: usize) -> Result<Vec<u8>> {
            self.reads.pop_front().ok_or("disconnected".into())
        }
        async fn write(&mut self, data: &[u8]) -> Result<()> {
            self.writes.push(data.to_vec());
            Ok(())
        }
        async fn control(&mut self, _: u8, _: u16, _: u16, _: &[u8]) -> Result<()> {
            Ok(())
        }
    }
    fn layout() -> Layout {
        Layout {
            interface: 1,
            alternate: 0,
            input: 0x81,
            output: 2,
            control: None,
        }
    }
    fn fake(code: u16) -> Fake {
        let [hi, lo] = code.to_be_bytes();
        Fake {
            reads: [
                vec![0x5f],
                vec![0xf5],
                vec![0xaf],
                vec![0xfa],
                vec![0xfd],
                vec![hi],
                vec![lo, 0],
                vec![0],
                vec![0xfc],
                vec![0x8a, 0, 0xca, 1, 0, 1, 0, 0],
            ]
            .into(),
            writes: vec![],
        }
    }
    #[test]
    fn identifies_fragmented_response_without_authorizing_flashing() {
        let mut port = fake(0x6582);
        let report = pollster::block_on(probe(&mut port, &layout())).unwrap();
        assert_eq!(report.hardware_version, 0xca01);
        assert!(report.compatible_chip);
        assert!(!report.y2_verified);
        assert!(!report.storage_written);
        assert_eq!(
            port.writes,
            vec![
                vec![0xa0],
                vec![0x0a],
                vec![0x50],
                vec![0x05],
                vec![0xfd],
                vec![0xfc]
            ]
        );
    }
    #[test]
    fn wrong_chip_is_reported_as_incompatible() {
        assert!(
            !pollster::block_on(probe(&mut fake(0x1234), &layout()))
                .unwrap()
                .compatible_chip
        );
    }
    #[test]
    fn rejects_chip_query_error_before_requesting_versions() {
        let mut port = fake(0x6582);
        port.reads[7] = vec![1];
        let error = pollster::block_on(probe(&mut port, &layout())).unwrap_err();
        assert!(error.contains("GET_HW_CODE returned a nonzero status"));
        assert!(!port.writes.contains(&vec![0xfc]));
    }
    #[test]
    fn rejects_version_query_error() {
        let mut port = fake(0x6582);
        port.reads.back_mut().unwrap()[7] = 1;
        let error = pollster::block_on(probe(&mut port, &layout())).unwrap_err();
        assert!(error.contains("GET_HW_SW_VER returned a nonzero status"));
    }
    #[test]
    fn recorded_ready_prefix_does_not_exhaust_handshake_or_flood_sync_bytes() {
        let mut port = fake(0x6582);
        // Captured 2026-09-06: seven READY banners (35 bytes) in the first
        // serial read. Expected replies after that prefix are simulated.
        let mut prefix: VecDeque<_> = b"READY".repeat(7).into_iter().map(|b| vec![b]).collect();
        prefix.append(&mut port.reads);
        port.reads = prefix;
        let report = pollster::block_on(probe(&mut port, &layout())).unwrap();
        assert!(report.compatible_chip);
        assert_eq!(
            port.writes,
            vec![
                vec![0xa0],
                vec![0xa0],
                vec![0x0a],
                vec![0x50],
                vec![5],
                vec![0xfd],
                vec![0xfc]
            ]
        );
    }
    #[test]
    fn endless_ready_announcements_are_bounded() {
        let mut port = Fake {
            reads: b"READY".repeat(65).into_iter().map(|b| vec![b]).collect(),
            writes: vec![],
        };
        let error = pollster::block_on(probe(&mut port, &layout())).unwrap_err();
        assert!(error.contains("keeps announcing READY"));
        assert_eq!(port.writes, vec![vec![0xa0], vec![0xa0]]);
    }
    #[test]
    fn disconnect_stops_before_identification() {
        let mut port = Fake {
            reads: [vec![0x5f]].into(),
            writes: vec![],
        };
        assert!(pollster::block_on(probe(&mut port, &layout())).is_err());
        assert!(!port.writes.contains(&vec![0xfd]));
    }
    #[test]
    fn never_loops_forever_on_wrong_echoes() {
        let mut port = Fake {
            reads: vec![vec![0]; 40].into(),
            writes: vec![],
        };
        assert!(pollster::block_on(probe(&mut port, &layout())).is_err());
        assert_eq!(port.writes.len(), 32);
    }
    #[test]
    fn candidate_filter_excludes_running_tempo_and_unrelated_mtk_usb() {
        assert!(is_candidate(0x0e8d, 0x2001));
        assert!(!is_candidate(0x0525, 0xa4aa));
        assert!(!is_candidate(0x0e8d, 0x0616));
    }
    #[test]
    fn ambiguous_endpoints_are_rejected() {
        let interface = Interface {
            number: 1,
            alternate: 0,
            class: 10,
            endpoints: vec![
                Endpoint {
                    address: 0x81,
                    bulk: true,
                },
                Endpoint {
                    address: 2,
                    bulk: true,
                },
            ],
        };
        assert_eq!(
            select_layout(std::slice::from_ref(&interface))
                .unwrap()
                .input,
            0x81
        );
        assert!(select_layout(&[interface.clone(), interface]).is_err());
    }
}
