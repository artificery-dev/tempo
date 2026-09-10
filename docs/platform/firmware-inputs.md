# Firmware inputs

Tempo builds its own kernel, root filesystem and player, but a Y2 does not
boot on those alone. The preloader, LK, the vendor partition tables, the
download agents that talk to a powered-off player, the charger screens in the
LOGO image, the modem firmware that wakes the radio hardware and the WiFi,
Bluetooth and FM firmware the kernel loads are all vendor binaries. They live
under `platform/firmware/`, the large ones through Git LFS, and this page
records which file feeds which part of the build and what stays out of the
repository altogether.

## Components

| Where | What |
| --- | --- |
| `platform/firmware/README.md` | The inventory of inputs and the pinned hashes of the two download agents and the modem firmware. |
| `platform/firmware/DA.img` | The legacy download agent Toolbox loads through the preloader. |
| `platform/firmware/stock/` | The stock boot chain, partition tables, scatter, LOGO, SEC_RO and modem firmware, plus the Rockbox download agent. |
| `platform/firmware/mediatek/mt6582/` | WiFi, Bluetooth and FM firmware the kernel embeds. |
| `platform/firmware/local/` | Gitignored: device-specific radio fixtures kept for local analysis. |
| `.gitattributes` | Which firmware paths go through Git LFS. |
| `config.yaml` `firmware:` | The public firmware version and `stock_rom`, the directory the distribution takes the boot chain from. |
| `packages/tempo_build/lib/src/bootstrap.dart` | `provisionFirmwareLfs`: hydrates the LFS blobs during bootstrap and refuses pointer files. |
| `packages/tempo_build/lib/src/distribution.dart` | `toolbox dev dist --full`: copies the stock chain into the scatter export. |
| `platform/recovery/pack.py` | Turns the Rockbox agent into Tempo Recovery's RAM-boot wrapper. |
| `packages/tempo_build/lib/src/modem_protocol.dart` | `modemFirmwareHash`, the pinned modem firmware hash. |
| `platform/kernel/config/y2.config` | `CONFIG_EXTRA_FIRMWARE`, the list of radio firmware built into the kernel. |

## The stock ROM

`firmware.stock_rom` points at `platform/firmware/stock/`. Its contents come
from the vendor's release for this player and are used as follows:

| File | Use |
| --- | --- |
| `preloader_eastaeon82_wet_kk.bin` | The `PRELOADER` row of the `--full` scatter export; DRAM configuration when Toolbox boots Tempo Recovery in RAM or talks to the boot ROM. |
| `lk.bin` | The `UBOOT` row of the `--full` scatter export. |
| `MBR`, `EBR1` | The vendor partition tables for the `--full` scatter export. |
| `EBR2` | Kept with the set; its partition is overwritten by the rootfs pieces. |
| `secro.img` | The `SEC_RO` row of the `--full` scatter export. |
| `MT6582_Android_scatter.txt` | Every partition name, size and address; the template for `Y2_MT6582_scatter.txt` and the source of Toolbox's partition map. |
| `logo.bin` | The template for the splash build: block 0 is replaced, the charger blocks are kept byte for byte. |
| `modem_1_2g_n.img` | The modem firmware run once at boot, see [Radio initialization](radio-initialization.md). |
| `rockbox-MTK_AllInOne_DA.bin` | The base download agent for Tempo Recovery's RAM boot. |

The `--full` chain is taken from here by name. `distributionCommand` picks the
first `preloader_*.bin` in sorted order, copies it with `MBR`, `EBR1`,
`lk.bin` and `secro.img` into `build/dist/spft/`, and enables those rows in
the generated scatter so SP Flash Tool can lay down a complete boot chain. The
`.y2-firmware` installer package never carries any of them; the boot chain on
a device is only ever replaced through the scatter export or a restore of that
device's own backup. See [Boot and flashing](boot-and-flashing.md).

The splash build requires `logo.bin` to exist unless `--bare` is given, and
the distribution passes `--bare` automatically when the template is missing.
The modem firmware must hash to `modemFirmwareHash`:

```
5059775975cbf6ab74c43978ca8f65d9a274b83585f456134e39b09f6dc7a4f1
```

## The download agents

Two different agents are carried, and the README pins both hashes.

`DA.img` is the legacy download agent. Toolbox loads it into a powered-off
player through the preloader's own protocol and uses it for reads and for the
Legacy Download Agent transport. The native engine looks for it beside the
`tempo-usb` executable, at `platform/firmware/DA.img` in a checkout, or at
`TEMPO_USB_AGENT`; `toolbox dev dist` also copies it into
`build/dist/spft/` for SP Flash Tool. Its SHA-256 is:

```
46cd175d7556e6e80b13f6a70827c6931a5dfa25a09c3cc50e75ba7ff9327618
```

`stock/rockbox-MTK_AllInOne_DA.bin` is a different build and is the base for
Tempo Recovery. `platform/recovery/pack.py` checks its hash, finds the single
MT6582 entry in its loader table, and replaces the stage hash of that entry
with the hash of Tempo's payload, so the agent's own first stage verifies and
runs the recovery kernel from RAM. The results are the matched pair
`build/recovery/ramboot-DA.bin` and `build/recovery/payload.bin`, next to a
copy of the stock preloader as `preloader.bin`. Its SHA-256 is:

```
4729b77976508708a541039a807f3203f68a37e91ebbc832ac7db70b4ea6d832
```

When Toolbox boots recovery it parses the EMI table out of that preloader
copy and hands it to the agent for DRAM setup. The preloader is read for its
configuration only; the RAM boot writes nothing to storage. See
[Tempo Recovery](recovery.md).

## Radio firmware in the kernel

`platform/firmware/mediatek/mt6582/` holds the WiFi RAM code, `WMT_SOC.cfg`,
the two Bluetooth patch files and the MT6627 FM patch, coefficient and
customisation files. `y2.config` sets `CONFIG_EXTRA_FIRMWARE_DIR` to
`platform/firmware` and lists all seven under `CONFIG_EXTRA_FIRMWARE`, so the
kernel image contains them and the drivers need no firmware files on the root
filesystem. The recovery kernel points at the same directory with an empty
list. These files are small and are ordinary Git blobs.

## Git LFS

`.gitattributes` routes three patterns through LFS:

```
platform/firmware/DA.img
platform/firmware/stock/*.bin
platform/firmware/stock/*.img
```

That covers both download agents, the preloader, `lk.bin`, `logo.bin`,
`secro.img` and the modem firmware. The scatter and the three 512-byte
partition tables are diffable and stay in the object store, as does
everything under `mediatek/`.

`toolbox dev bootstrap` hydrates the blobs without needing a system LFS
client. `provisionFirmwareLfs` copies the toolchain container's `git-lfs`
binary to `<git common dir>/tempo/bin/`, where it survives a cleaned `build/`
or a removed worktree, sets `filter.lfs.required` and the clean, smudge and
process filters to that binary, then pulls `platform/firmware/**` on the host
so the developer's own Git credentials are used. Afterwards every LFS-tracked
file under `platform/firmware/` is checked to exist, to be non-empty and not
to begin with the LFS pointer header; a pointer left in place fails bootstrap.

## What is never committed

| Path | Why |
| --- | --- |
| `platform/firmware/local/` | Player-specific modem captures and fixtures. They are provisioned locally, like `config.local.yaml`, and never published. |
| `config.local.yaml` | The default user's password and SSH keys. |
| `build/` | Everything generated, including `build/recovery/` and the distribution set. |
| `/archive/` | Ignored at the repository root. |

`platform/firmware/README.md` states the rule for the firmware directory:
no player NVRAM, identity records, filesystem exchanges or RAM captures may
be added to it or to distributable images. The radio bootstrap creates its
transient state from the vendor firmware on the player rather than replaying
a capture, and the distribution build refuses a rootfs image that still holds
one. Historical private captures stay under the ignored `local/` directory.

## Versioning

`firmware.version` in `config.yaml` is the public firmware version that
`toolbox dev dist` writes into the installer manifest, together with the
source commit it records separately. The vendor inputs carry no version of
their own beyond the hashes pinned in the README and in code.
