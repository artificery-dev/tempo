# Y2 firmware inputs

These vendor binaries remain production inputs. Historical tools and duplicate
reference binaries are excluded from this repository.

| Input | Use |
| --- | --- |
| `DA.img` | Legacy Download Agent transfers in Toolbox. |
| `stock/rockbox-MTK_AllInOne_DA.bin` | Base agent for the Tempo Recovery RAM-boot wrapper. |
| `stock/preloader_eastaeon82_wet_kk.bin` | DRAM configuration for boot-mode connections. |
| `stock/modem_1_2g_n.img` | Vendor modem firmware for brief radio initialization. |
| `stock/logo.bin` | Template retaining the bootloader's charging images. |
| Remaining `stock/` images and scatter | Vendor boot-chain inputs and legacy scatter export. |
| `mediatek/` | Runtime Wi-Fi, Bluetooth and FM firmware. |

The legacy DA's SHA-256 is
`46cd175d7556e6e80b13f6a70827c6931a5dfa25a09c3cc50e75ba7ff9327618`;
the recovery wrapper's base DA is
`4729b77976508708a541039a807f3203f68a37e91ebbc832ac7db70b4ea6d832`.
They are different agents. Bootstrap hydrates both with Git LFS. The modem firmware is extracted from `/system/etc/firmware/modem_1_2g_n.img`
in the stock `y2_v3.2.0_FM-20260813` release. Its SHA-256 is
`5059775975cbf6ab74c43978ca8f65d9a274b83585f456134e39b09f6dc7a4f1`.
It matches the vendor firmware used in the earlier hardware experiments.

Do not add player NVRAM, identity records, filesystem exchanges, or RAM captures
to this directory or to distributable images. Radio startup creates transient
state from the vendor firmware on the player; it does not replay a capture.
Historical private captures can remain under ignored `local/` for local audits.

Toolbox imports both legacy scatter ROMs and native `.y2-firmware` packages
directly; the external SP Flash Tool distribution is not required.
