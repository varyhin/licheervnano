# licheervnano

[Русский](README.md) | English | [中文](README.zh.md)

Complete mainline build pipeline for the Sipeed LicheeRV Nano board
(Sophgo SG2002 SoC, RISC-V C906 at 1 GHz, 0.5 TOPS INT8 TPU). A single
`make image` produces a bootable SD image with the
FSBL → OpenSBI → U-Boot → Linux 6.18 → Debian 13 chain and support for
all four board variants: B (no networking), E (Ethernet), W (Wi-Fi 6),
WE (Ethernet + Wi-Fi 6).

Everything is verified on real hardware over UART. The closed vendor
footprint is minimal: 21 KiB of boot blobs (DDR parameters and the
small-core FreeRTOS) plus the AIC8800D80 radio firmware for W/WE.

## Source model

Every component except the Linux kernel is stored as a snapshot under
`src/` in this repository. The default build uses these snapshots and
never touches the network. For each component `manifest/sources.mk`
records a pinned SHA and the official upstream URL, so the source can
always be switched:

- `make refetch COMP=u-boot SOURCE=upstream` re-downloads the pinned
  tree from the official repository over `src/u-boot`
- an empty `git status` afterwards proves the snapshot is identical to
  upstream (a free drift check)

The kernel is not stored in the repository. `make fetch-linux` clones
`v6.18.29` from kernel.org and verifies the SHA against the pin. The
rootfs is built with debootstrap from deb.debian.org.

| Component | Version / pin | Purpose |
|---|---|---|
| linux | v6.18.29 (cloned) | kernel |
| u-boot | v2025.10 | S-mode bootloader |
| opensbi | v1.8.1 | M-mode SBI firmware |
| fiptool | 7f59889 | FIP container packing |
| licheerv-nano-build-vendor | d4003f15 | FSBL (vendor TF-A), blobs |
| aic8800-vendor | d4003f15 | Wi-Fi 6 / BT SDIO driver |
| cvitek-tpu-vendor | d4003f15 | TPU kernel driver |

The userspace TPU stack (cviruntime, cvikernel, cvibuilder, cnpy, zlib,
the tpu-mlir container, the bench kit) is not part of this repository
and is maintained separately.

## Quick start

Host: Debian 13 amd64 (or compatible), root for debootstrap and image
packing.

```sh
apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
  device-tree-compiler u-boot-tools build-essential bc bison flex \
  libssl-dev libelf-dev libncurses-dev python3 parted dosfstools rsync \
  debootstrap qemu-user-static binfmt-support git

git clone <this repository> && cd licheervnano
make rootfs        # debootstrap Debian 13 + packages (~5 min, internet)
make image         # full build: patches, u-boot, opensbi, fsbl, kernel,
                   # modules, fip, SD image packing
```

Result: `images/licheervnano.img` and `images/licheervnano.img.gz`.
Flashing: balenaEtcher accepts `.img.gz` directly, or use
`dd if=images/licheervnano.img of=/dev/sdX bs=4M conv=fsync`.

Console: UART0, 115200 8N1. The board variant is selected in the U-Boot
extlinux menu at boot (default E, a few seconds timeout). Login root,
password sipeed (override with the `ROOT_PASSWORD` variable).

Individual steps: `make help`.

## Repository layout

| Directory | Purpose |
|---|---|
| `manifest/` | SHA pins and URLs of all components |
| `src/` | source snapshots (the kernel is cloned here too) |
| `patches/` | local patches on top of pristine snapshots (diff -u format) |
| `overlay/` | new files copied over the snapshots at build time |
| `firmware/` | vendor blobs + self-built FSBL (see NOTICE.md) |
| `extlinux/` | boot menu for the four board variants |
| `scripts/` | refetch, usb-gadget, SSH key hygiene |
| `docs/` | peripheral and build guides |
| `build/`, `rootfs/`, `images/` | derived artifacts, gitignored |

## Patches and overlay

Snapshots in `src/` always stay pristine. Local changes live only in
`patches/` (true modifications of upstream files, strictly `diff -u`
format, no index lines) and `overlay/` (new files). `make patches-apply`
applies them to the working tree, `make patches-revert` restores the
pristine state. Application is verified with `git status`, not the exit
code: `git apply` silently skips `git diff` formatted patches with blob
index lines in this layout.

`make patches-check` falsely fails on the create-then-modify chain
(patch 0001 creates the board DTS files, later patches modify them).
The real check is `make patches-apply` on a clean tree.

## Updating a component version

1. Update the pin in `manifest/sources.mk`.
2. `make refetch COMP=<name> SOURCE=upstream`.
3. Re-check patches (`make patches-apply`), build, verify on hardware.
4. Commit the `src/<name>` change together with the manifest in one commit.

## Peripherals

Status on the WE variant, everything listed is verified on the board.

| Peripheral | Status | Document |
|---|---|---|
| UART, GPIO, pinmux | working | [docs/uart_setup.md](docs/uart_setup.md), [docs/gpio_setup.md](docs/gpio_setup.md) |
| Ethernet 100M (E/WE) | working | built-in EPHY, ephy-init patch |
| Wi-Fi 6 + BT 5 (W/WE) | working | [docs/wifi_setup.md](docs/wifi_setup.md) |
| USB gadget (ACM console) | working | [docs/usb_setup.md](docs/usb_setup.md) |
| Audio (mic + speaker) | working | [docs/audio_setup.md](docs/audio_setup.md) |
| TPU (0.5 TOPS INT8, BF16) | working | [docs/tpu_sg2002.md](docs/tpu_sg2002.md) |
| RTC | working | [docs/rtc_setup.md](docs/rtc_setup.md) |
| Watchdog | working | [docs/watchdog_setup.md](docs/watchdog_setup.md) |
| Thermal sensor | working | [docs/thermal_setup.md](docs/thermal_setup.md) |
| LEDs, triggers | working | [docs/led_setup.md](docs/led_setup.md) |
| I2C, ADC | working | [docs/i2c_setup.md](docs/i2c_setup.md), [docs/adc_setup.md](docs/adc_setup.md) |
| SG2002 pin map | reference | [docs/sg2002_pin_map.md](docs/sg2002_pin_map.md) |

Display (MIPI DSI), camera (ISP) and the video codec (VPU) are not yet
supported in the mainline stack; these are closed or heavy vendor blocks.

## TPU

Inference on the built-in TPU works through a forward port of the vendor
driver (`soph_tpu.ko`, built automatically). This repository hosts the
kernel side: the driver, the `cvitek,tpu` DT node and the
`CVITPU_GET_PADDR` ioctl contract. The userspace stack (runtime
cross-build, model compilation with the tpu-mlir container, bench kit,
the full pipeline from ONNX to running on the board) is not part of
this repository.
See [docs/tpu_sg2002.md](docs/tpu_sg2002.md) for the TPU block overview.
Anchor number: mobilenet_v2 BF16 about 22 ms at 700 MHz.

## Licensing

The project's own glue is MIT licensed (see LICENSE). Every snapshot in
`src/` keeps its upstream license. Binary blob provenance and status are
described in [NOTICE.md](NOTICE.md). Russian is the primary
documentation language of this repository; the English and Chinese
READMEs are translations.
