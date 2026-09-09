# Active diagnostics

These tools support current device investigations. Retired bring-up tools and
their captured evidence are maintained separately.

Capture an already-connected Y2 A2DP source on the receiving Linux host:

```sh
toolbox dev diagnostics capture-a2dp [BLUETOOTH_ADDRESS] [OUTPUT_DIRECTORY]
```

The default peer is `00:00:46:65:82:01` and the default output is `build/btdiag`.
The host needs `pactl` and `pw-record`. The command reuses or creates the silent
`bt_diag` sink, routes only that Bluetooth peer's streams, and records its monitor
as 48 kHz stereo signed 16-bit PCM WAV. A sibling `.meta` records timestamps,
peer, sink index, and PCM format. Stop with Ctrl-C; the sink remains reusable.

The source entry point is `tool/capture_a2dp.dart`, backed by the shared
`toolbox_core` capture API. It replaces `btdiag/capture-a2dp`; jq and Bash are no
longer required by this capture workflow. Source, routing/refusal, metadata,
recording exit codes, and cancellation are covered by mocked host tests; those
tests do not establish live Bluetooth/audio timing performance.

Measure continuity in a captured steady tone with:

```sh
toolbox dev diagnostics analyze-tone capture.wav --minimum-gap-ms 5
```

This uses the shared `toolbox_core` analyzer; `tool/analyze_tone.dart` is a thin
entry point to the same developer route. Exit codes are 0 for continuous tone,
1 for no active tone, 2 for dropouts, and 64 for invalid input. Leading/trailing
silence is excluded. Use a steady test tone, not arbitrary music or speech.
`device-screenshot.c` supports the shared live-device screenshot operation.
