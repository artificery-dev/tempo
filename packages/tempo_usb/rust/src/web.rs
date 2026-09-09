use js_sys::{Promise, Uint8Array};
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::JsFuture;

use crate::{Interface, Layout, Result, Transport, da, probe, select_layout};

// The adapter owns browser USBDevice objects and permission gestures. All
// protocol bytes, endpoint policy and identity decisions remain in Rust.
#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_name = setTimeout, catch)]
    fn set_timeout(
        callback: &js_sys::Function,
        milliseconds: u32,
    ) -> std::result::Result<JsValue, JsValue>;
    pub type BrowserPort;
    #[wasm_bindgen(method, catch)]
    fn read(this: &BrowserPort, length: usize) -> std::result::Result<Promise, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn write(this: &BrowserPort, bytes: &[u8]) -> std::result::Result<Promise, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn control(
        this: &BrowserPort,
        request: u8,
        value: u16,
        index: u16,
        bytes: &[u8],
    ) -> std::result::Result<Promise, JsValue>;
    #[wasm_bindgen(method, js_name = resumeForReset)]
    fn resume_for_reset(this: &BrowserPort);
    pub type BrowserBackupSink;
    #[wasm_bindgen(method, catch)]
    fn start(this: &BrowserBackupSink, total: f64) -> std::result::Result<(), JsValue>;
    #[wasm_bindgen(method, catch, js_name = writeChunk)]
    fn write_chunk(
        this: &BrowserBackupSink,
        bytes: &[u8],
        completed: f64,
        total: f64,
    ) -> std::result::Result<Promise, JsValue>;
    pub type BrowserFirmwareSource;
    #[wasm_bindgen(method, catch, js_name = readChunk)]
    fn read_firmware_chunk(
        this: &BrowserFirmwareSource,
        image: usize,
        offset: f64,
        length: usize,
    ) -> std::result::Result<Promise, JsValue>;
    pub type BrowserFlashObserver;
    #[wasm_bindgen(method, catch)]
    fn progress(this: &BrowserFlashObserver, event: &str) -> std::result::Result<(), JsValue>;
}

struct WebBackupSink(BrowserBackupSink);

impl da::BackupSink for WebBackupSink {
    async fn chunk(&mut self, bytes: &[u8], completed: u64, total: u64) -> Result<()> {
        JsFuture::from(
            self.0
                .write_chunk(bytes, completed as f64, total as f64)
                .map_err(error)?,
        )
        .await
        .map_err(error)?;
        Ok(())
    }
}

struct WebFirmwareSource(BrowserFirmwareSource);

impl crate::firmware::FirmwareSource for WebFirmwareSource {
    async fn chunk(&mut self, image: usize, offset: u64, length: usize) -> Result<Vec<u8>> {
        let response = JsFuture::from(
            self.0
                .read_firmware_chunk(image, offset as f64, length)
                .map_err(error)?,
        )
        .await
        .map_err(error)?;
        Ok(Uint8Array::new(&response).to_vec())
    }
}

struct WebFlashObserver(BrowserFlashObserver);

impl crate::firmware::FlashObserver for WebFlashObserver {
    async fn progress(&mut self, event: crate::firmware::FlashProgress) -> Result<()> {
        let event = serde_json::to_string(&event).map_err(|e| e.to_string())?;
        self.0.progress(&event).map_err(error)
    }
}

pub(crate) async fn delay(milliseconds: u32) -> Result<()> {
    let promise = Promise::new(&mut |resolve, reject| {
        if let Err(value) = set_timeout(&resolve, milliseconds) {
            let _ = reject.call1(&JsValue::UNDEFINED, &value);
        }
    });
    JsFuture::from(promise).await.map_err(error)?;
    Ok(())
}

fn error(value: JsValue) -> String {
    if let Some(message) = value.as_string() {
        return message;
    }
    if let Ok(message) = js_sys::Reflect::get(&value, &JsValue::from_str("message"))
        && let Some(message) = message.as_string()
    {
        return message;
    }
    js_sys::JSON::stringify(&value)
        .ok()
        .and_then(|s| s.as_string())
        .filter(|s| s != "{}")
        .unwrap_or_else(|| format!("{value:?}"))
}

impl Transport for BrowserPort {
    async fn read(&mut self, length: usize) -> Result<Vec<u8>> {
        let response = JsFuture::from(BrowserPort::read(self, length).map_err(error)?)
            .await
            .map_err(error)?;
        Ok(Uint8Array::new(&response).to_vec())
    }
    async fn write(&mut self, data: &[u8]) -> Result<()> {
        JsFuture::from(BrowserPort::write(self, data).map_err(error)?)
            .await
            .map_err(error)?;
        Ok(())
    }
    async fn control(&mut self, request: u8, value: u16, index: u16, data: &[u8]) -> Result<()> {
        JsFuture::from(BrowserPort::control(self, request, value, index, data).map_err(error)?)
            .await
            .map_err(error)?;
        Ok(())
    }
}

#[wasm_bindgen]
pub fn usb_layout(interfaces: &str) -> std::result::Result<String, JsValue> {
    let interfaces: Vec<Interface> =
        serde_json::from_str(interfaces).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let layout = select_layout(&interfaces).map_err(|e| JsValue::from_str(&e))?;
    serde_json::to_string(&layout).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn inspect_firmware(manifest_bytes: &[u8]) -> std::result::Result<String, JsValue> {
    let manifest =
        crate::firmware::Manifest::parse(manifest_bytes).map_err(|e| JsValue::from_str(&e))?;
    serde_json::to_string(&manifest).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub async fn verify_firmware(
    manifest_bytes: &[u8],
    source: BrowserFirmwareSource,
    observer: BrowserFlashObserver,
) -> std::result::Result<String, JsValue> {
    let manifest =
        crate::firmware::Manifest::parse(manifest_bytes).map_err(|e| JsValue::from_str(&e))?;
    let mut source = WebFirmwareSource(source);
    let mut observer = WebFlashObserver(observer);
    let bytes = crate::firmware::verify(&manifest, &mut source, &mut observer)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    serde_json::to_string(&serde_json::json!({
        "firmware": manifest.firmware,
        "images": manifest.images.len(),
        "bytes": bytes,
        "includes_preloader": manifest.images.iter().any(|image| image.writes.iter().any(|write| write.region == crate::firmware::Region::Boot1)),
    }))
    .map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub async fn probe_usb(
    mut port: BrowserPort,
    layout: &str,
) -> std::result::Result<String, JsValue> {
    let layout: Layout =
        serde_json::from_str(layout).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let report = probe(&mut port, &layout)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    serde_json::to_string(&report).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub async fn backup_usb(
    mut port: BrowserPort,
    layout: &str,
    agent_bytes: &[u8],
    sink: BrowserBackupSink,
    reboot_after_success: bool,
) -> std::result::Result<String, JsValue> {
    let layout: Layout =
        serde_json::from_str(layout).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let mut report = probe(&mut port, &layout)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    let agent = da::Agent::parse(agent_bytes, &report).map_err(|e| JsValue::from_str(&e))?;
    let geometry = da::initialize(&mut port, &agent)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    if !geometry.is_y2() {
        return Err(JsValue::from_str(
            "The eMMC geometry does not match an Innioasis Y2",
        ));
    }
    report.y2_verified = true;
    let total = geometry.image_size().map_err(|e| JsValue::from_str(&e))?;
    let mut sink = WebBackupSink(sink);
    let transfer = async {
        sink.0.start(total as f64).map_err(error)?;
        da::read_region(&mut port, 8, total, 0, total, &mut sink).await
    }
    .await;
    port.resume_for_reset();
    let reset = if reboot_after_success {
        da::reboot(&mut port).await
    } else {
        Ok(())
    };
    if let Err(transfer_error) = transfer {
        return Err(JsValue::from_str(&match reset {
            Ok(()) => transfer_error,
            Err(reset_error) => {
                format!("{transfer_error}. The Y2 also could not be reset: {reset_error}")
            }
        }));
    }
    reset.map_err(|e| JsValue::from_str(&e))?;
    serde_json::to_string(&serde_json::json!({
        "report": report,
        "geometry": geometry,
        "bytes": total,
        "format": "raw-emmc-gzip"
    }))
    .map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub async fn flash_usb(
    mut port: BrowserPort,
    layout: &str,
    agent_bytes: &[u8],
    manifest_bytes: &[u8],
    source: BrowserFirmwareSource,
    observer: BrowserFlashObserver,
    allow_preloader: bool,
    verify_write: bool,
    reboot_after_success: bool,
) -> std::result::Result<String, JsValue> {
    let layout: Layout =
        serde_json::from_str(layout).map_err(|e| JsValue::from_str(&e.to_string()))?;
    let manifest =
        crate::firmware::Manifest::parse(manifest_bytes).map_err(|e| JsValue::from_str(&e))?;
    let mut report = probe(&mut port, &layout)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    let agent = da::Agent::parse(agent_bytes, &report).map_err(|e| JsValue::from_str(&e))?;
    let geometry = da::initialize(&mut port, &agent)
        .await
        .map_err(|e| JsValue::from_str(&e))?;
    if !geometry.is_y2() {
        return Err(JsValue::from_str(
            "The eMMC geometry does not match an Innioasis Y2",
        ));
    }
    report.y2_verified = true;
    let mut source = WebFirmwareSource(source);
    let mut observer = WebFlashObserver(observer);
    // FirmwareDestination stages immutable File snapshots and calls
    // verify_firmware before the picker opens, so do not leave the DA waiting
    // while hashing the full archive again.
    let transfer = crate::firmware::flash_with_options(
        &mut port,
        &geometry,
        &manifest,
        &mut source,
        &mut observer,
        crate::firmware::WriteOptions {
            allow_preloader,
            resume: false,
            verify_write,
        },
    )
    .await;
    port.resume_for_reset();
    let reset = if reboot_after_success {
        da::reboot(&mut port).await
    } else {
        Ok(())
    };
    let bytes = match transfer {
        Ok(bytes) => bytes,
        Err(transfer_error) => {
            return Err(JsValue::from_str(&match reset {
                Ok(()) => transfer_error,
                Err(reset_error) => {
                    format!("{transfer_error}. The Y2 also could not be reset: {reset_error}")
                }
            }));
        }
    };
    reset.map_err(|e| JsValue::from_str(&e))?;
    report.storage_written = true;
    serde_json::to_string(&serde_json::json!({
        "report": report,
        "geometry": geometry,
        "bytes": bytes,
        "firmware": manifest.firmware,
    }))
    .map_err(|e| JsValue::from_str(&e.to_string()))
}
