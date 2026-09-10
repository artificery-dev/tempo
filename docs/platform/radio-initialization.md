# Radio initialization

The Y2 briefly runs its stock MT6582 modem firmware to initialize the shared
radio hardware before Bluetooth starts. It then powers the modem off. This
helper does not provide cellular service.

The release input is `platform/firmware/stock/modem_1_2g_n.img`, extracted from
`/system/etc/firmware/modem_1_2g_n.img` in the stock FM 20260813 package. SHA-256:
`5059775975cbf6ab74c43978ca8f65d9a274b83585f456134e39b09f6dc7a4f1`.
It is identical to the vendor executable used in the earlier experiments.

## Runtime data

`modem_runtime.dart` generates the CCCI memory layout from protocol fields,
addresses and sizes. It starts with zeroed memory, not a captured RAM image.
The ABI is described in the [MT6582 CCCI driver](https://android.googlesource.com/kernel/mediatek/+/android-4.4.4_r3/drivers/misc/mediatek/dual_ccci/ccci_md_main.c)
and its platform setup.

`modem_filesystem.dart` serves the pinned firmware's startup filesystem requests
from a bounded RAM filesystem. The modem creates its own records during startup.
No recorded filesystem responses are replayed, and no writes reach eMMC,
including requests using the modem's X: and Y: drive names. Existing device
NVRAM and protected partitions are untouched. Each invocation starts fresh.

The helper checks the board and reserved memory, takes an exclusive modem lock,
validates the vendor firmware hash, waits for boot-ready and five seconds of
filesystem inactivity, then checks hardware shutdown. Unsupported protocol
requests and resource limits fail closed and enter the same shutdown path.
This is a Y2 startup helper, not a general modem filesystem implementation.

## Distribution boundary

Player captures, NVRAM, identity records and RAM snapshots are not release
assets. The former `--fixture` bootstrap input and capture loader have been
removed. Rootfs staging removes the former embedded fixture; packaging also
checks the rootfs itself so an older cached image cannot ship those captures.
Local historical captures remain ignored for private analysis.

## Validation

On the connected Y2, the experimental responder completed 841 requests and
created 83 transient files using only vendor firmware and generated shared
memory. It reached boot-ready and shut MD1 down; both hardware status registers
were `0x3f5e` with the modem power bit clear.

All 67 file reads in this player's earlier captured startup matched slices of
the newly generated records: 30 calibration reads, two identity reads and 35
other runtime reads. This comparison does not establish that every Y2 has the
same records, and is not a reason to distribute the original capture.

The actual ARM Dart helper also completed 841 requests on the player and
verified modem shutdown. Nineteen focused tests passed, including protocol,
filesystem isolation/bounds, bootstrap and distribution tests. Static analysis
passed. A true power-off cold boot, Classic Bluetooth discovery and audio
acceptance remain required before calling the replacement release-validated.
