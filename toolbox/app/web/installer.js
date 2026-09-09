// wasm-bindgen exports an ES module; all authored device/storage policy is Dart.
window.tempoUsbWasmReady = (async () => {
  const engine = await import('./pkg/tempo_installer.js');
  await engine.default();
  return engine;
})();
// Avoid an unhandled rejection before Flutter installs its startup error UI.
window.tempoUsbWasmReady.catch(() => {});
void import('./flutter_bootstrap.js');
