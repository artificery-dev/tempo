# Firmware packages

A `.y2-firmware` package is the unit Toolbox installs: a ZIP archive whose
first entry is a manifest describing the Innioasis Y2's eMMC geometry, the
firmware's identity, and a list of images with the byte ranges each one is
written to. The format is deliberately explicit. A package names every target
range in raw eMMC coordinates, carries the size and SHA-256 of every image, and
is rejected unless every declared range fits its region and no two ranges
overlap. The same manifest structure is built in memory for restores and for
legacy scatter ROM imports, so one write plan and one policy serve all three.

## Components

| Where | What |
| --- | --- |
| `packages/tempo_usb/firmware/manifest.schema.json` | The JSON Schema for the manifest. |
| `packages/tempo_usb/firmware/example-manifest.json` | A canonical example, parsed by the crate's tests. |
| `packages/tempo_usb/rust/src/firmware.rs` | `Manifest`, its validation, `write_plan` and the preloader header check. |
| `packages/tempo_usb/rust/src/package.rs` | The strict ZIP reader, `inspect`, and `PreparedPackage` staging. |
| `packages/tempo_usb/rust/src/spft.rs` | Legacy scatter ROM preview and import. |
| `packages/tempo_usb/rust/src/sparse_image.rs` | A seekable view of Android sparse images without expanding them. |
| `packages/tempo_usb/rust/src/restore.rs` | Builds the same manifest from a backup. |
| `packages/tempo_build/lib/src/tempo_layout.dart` | `TempoLayout` and `tempoInstallerManifest`, the manifest for Tempo's own layout. |
| `packages/tempo_build/lib/src/distribution.dart` | `writeTempoInstallerArchive` and the packaging script `toolbox dev dist` runs. |
| `toolbox/app/lib/engine_native.dart` | Preview, staging and the logo thumbnail for the GUI. |
| `packages/tempo_usb/lib/src/browser/archive.dart`, `storage.dart` | The browser's ZIP reader and origin-private staging. |

## The archive

The package is a ZIP file read with these rules, in `package.rs` for native
builds and `archive.dart` in the browser:

- The archive starts at byte zero and no entries overlap.
- `manifest.json` is the first entry and is at most 1 MiB.
- Entries are stored or deflated, unencrypted, with UTF-8 names, and are
  neither directories nor symlinks.
- There are at most 257 entries. Every entry after the manifest must be
  referenced by the manifest, appear once, and have exactly the declared size.
- Image paths start with `images/`, contain no backslash and no `.` or `..`
  component.

`toolbox dev dist` writes packages with deflate at level 1 and ZIP64 enabled,
so a multi-gigabyte rootfs is an ordinary entry.

## The manifest

`manifest.json` has four top-level members and no others. Unknown fields are
refused by the parser, which uses `deny_unknown_fields` throughout.

| Field | Value |
| --- | --- |
| `format` | `dev.artificery.tempo.y2-firmware` |
| `format_version` | `1` |
| `device.id` | `innioasis-y2` |
| `device.hardware_code`, `device.hardware_subcode` | `25986` and `35328`, the MT6582's `0x6582` and `0x8a00`. |
| `device.storage.boot1`, `boot2`, `user` | `4194304`, `4194304` and `7818182656` bytes. |
| `firmware.id`, `firmware.name`, `firmware.version` | Non-empty identity strings. |
| `firmware.commit` | Optional. Shown truncated to seven characters in the GUI. |
| `firmware.icon` | Optional `data:image/png;base64,` PNG of at most 128 KiB; a preview, never a flashable image. |
| `images[].file` | The archive entry, under `images/`. |
| `images[].size`, `images[].sha256` | The uncompressed length and lowercase hex SHA-256. |
| `images[].writes[]` | One or more mappings from the image onto the chip. |

Each mapping has a `name`, a `region` of `boot1`, `boot2` or `user`, and
`source_offset`, `target_offset` and `length` in bytes. All three must be
multiples of 512, the source range must lie inside the image, the target range
must lie inside the region's capacity, and no two mappings in the package may
overlap on the same region. A package may hold up to 256 images and each image
up to 4096 mappings. The device fields are compared with constants and with
the geometry the chip reports, so a package for another device is rejected
before any transfer.

```json
{
  "format": "dev.artificery.tempo.y2-firmware",
  "format_version": 1,
  "device": {
    "id": "innioasis-y2",
    "hardware_code": 25986,
    "hardware_subcode": 35328,
    "storage": { "boot1": 4194304, "boot2": 4194304, "user": 7818182656 }
  },
  "firmware": { "id": "tempo", "name": "Tempo", "version": "0.9.0" },
  "images": [
    {
      "file": "images/boot.img",
      "size": 8388608,
      "sha256": "…",
      "writes": [
        { "name": "boot", "region": "user",
          "source_offset": 0, "target_offset": 43008000, "length": 8388608 }
      ]
    }
  ]
}
```

`manifest.schema.json` describes the same structure for external tools. Its
`firmware` object lists only `id`, `name` and `version`; the parser also
accepts the optional `commit` and `icon` members that Tempo's packages carry.

## Validation and staging

`toolbox inspect FILE` and the GUI's package preview run `inspect`, which
checks the archive rules, parses and validates the manifest, and reports the
identity, image count, mapping count, total bytes and whether any mapping
targets `boot1`. Nothing is decompressed.

Before a device is opened the package is prepared. `PreparedPackage::prepare`
creates a private directory, mode `0700`, and extracts each image to
`image-<n>.bin`, hashing the bytes as they stream and turning all-zero blocks
into holes. An image that expands past its declared size, ends short of it, or
hashes differently fails the whole preparation and the directory is removed.
The GUI stages under the application cache directory in `firmware-staging`
rather than the system temporary directory, deletes the previous staging
before starting a new one, and retains the result with a
`prepared-manifest.json` so the flash step reopens the directory instead of the
archive. A reopened directory is hashed again, so a staged image that has been
altered is refused. In the browser the same steps run against origin private
file storage, and the helper's `inspect_firmware` export validates the
manifest bytes.

The write plan is derived from the validated manifest at flash time. It
contains every mapping except `boot1` mappings, which are included only when
preloader flashing is enabled; see
[Device operations](device-operations.md#the-boot1-and-preloader-policies).

## Tempo's own package

`toolbox dev dist` produces `build/dist/<hostname>.y2-firmware` from the built
images with `tempoInstallerManifest`. The manifest maps five images onto the
USER area at the raw offsets of `TempoLayout`, each padded to a 512-byte
boundary and refused if it exceeds its range:

| Mapping | File | Target offset | Capacity |
| --- | --- | ---: | ---: |
| `boot` | `images/boot.img` | `0x2900000` | `0x1000000` |
| `recovery` | `images/recovery.img` | `0x3900000` | `0x1000000` |
| `splash` | `images/logo.img` | `0x4f80000` | `0x200000` |
| `rootfs` | `images/rootfs.ext4` | `0x5180000` | to the end of USER |
| `partition-table` | `images/partition-table.bin` | `0` | `512` |

The partition table is listed last so that it is published only after the
filesystem it names is on the chip. The identity is `tempo`, `Tempo` and
`firmware.version` from `config.yaml`, with the source commit and the
`assets/tempo/web/icon-192.png` icon embedded. There is no `boot1` or `boot2`
mapping, so the vendor preloader and LK are untouched by an install. The
archive is written by a Python script in the toolchain container that hashes
each image while streaming it into the ZIP, then reopens the finished archive
and hashes every entry again before the file is renamed into place. The eMMC
layout behind these offsets is described in
[Boot and flashing](../platform/boot-and-flashing.md).

## Legacy scatter ROM import

Toolbox also installs a vendor-style SP Flash Tool ROM directly, so no
external flashing tool is needed. The GUI accepts a `.zip`, a scatter `.txt`
or a dropped folder; the browser build accepts only `.y2-firmware`. `spft.rs`
turns the ROM into the same prepared package:

- The input is a ZIP containing exactly one `*scatter.txt`, a folder
  containing exactly one, or the scatter file itself. Image names are plain
  file names resolved beside the scatter, and a name that leaves the folder
  is refused.
- The scatter must declare `platform: MT6582` and
  `project: eastaeon82_wet_kk`, and must pass the same checks as the stock
  scatter: `linear_start_addr` exceeds `physical_start_addr` by `0x1400000`
  on every USER row, the rows are contiguous, and `MBR`, `EBR1`, `BOOTIMG`,
  `LOGO` and `FAT` are present.
- Only rows with `is_download: true` in region `EMMC_USER` are imported. Each
  becomes one mapping named after the partition, targeted at
  `physical_start_addr + 0xb80000`, which is the raw USER offset of the vendor
  partition. The preloader row is not in `EMMC_USER`, so a ROM never carries a
  BOOT1 write and the GUI labels the package `Preloader excluded`.
- An image starting with the Android sparse magic is staged as
  `image-<n>.sparse` and read through `sparse_image.rs`, which serves raw,
  fill and skipped chunks without expanding the file; any other image is
  padded to 512 bytes. Sizes must fit the partition and the USER area.
- The manifest identity is `legacy-spft`, the file stem as the name, and the
  version `Not specified`.

Before staging, `preview-spft` reports the identity and decodes the first
block of the `LOGO` image, a 480 by 360 RGB565 picture, into a 120 by 90
thumbnail that the GUI converts to the package icon. A logo that cannot be
decoded produces a warning on the chooser rather than a failure. The
distribution's `build/dist/spft/` scatter export is a different artefact: it
preserves the vendor layout for SP Flash Tool and is not what Toolbox
installs.
