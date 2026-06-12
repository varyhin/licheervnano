# licheervnano

[Русский](README.md) | [English](README.en.md) | 中文

Sipeed LicheeRV Nano 开发板（Sophgo SG2002 SoC，RISC-V C906 1 GHz，
0.5 TOPS INT8 TPU）的完整主线（mainline）构建流水线。一条 `make image`
命令即可生成可启动的 SD 卡镜像，启动链为
FSBL → OpenSBI → U-Boot → Linux 6.18 → Debian 13，并支持四种板型：
B（无网络）、E（以太网）、W（Wi-Fi 6）、WE（以太网 + Wi-Fi 6）。

所有功能均已在真实硬件上通过 UART 验证。闭源 vendor 部分极小：
21 KiB 启动 blob（DDR 参数和小核 FreeRTOS），以及 W/WE 板型所需的
AIC8800D80 无线固件。

## 源码模型

除 Linux 内核外，所有组件都以快照形式保存在本仓库的 `src/` 目录中。
默认构建直接使用这些快照，无需联网。`manifest/sources.mk` 为每个组件
记录了固定的 SHA 和官方上游 URL，因此源可以随时切换：

- `make refetch COMP=u-boot SOURCE=upstream` 从官方仓库按固定 SHA
  重新下载源码树并覆盖 `src/u-boot`
- 之后 `git status` 为空即证明快照与上游完全一致（零成本漂移检查）

内核不保存在仓库中，`make fetch-linux` 从 kernel.org 克隆 `v6.18.29`
并校验 SHA。rootfs 使用 debootstrap 从 deb.debian.org 构建。

| 组件 | 版本 / SHA | 用途 |
|---|---|---|
| linux | v6.18.29（克隆） | 内核 |
| u-boot | v2025.10 | S-mode 引导加载器 |
| opensbi | v1.8.1 | M-mode SBI 固件 |
| fiptool | 7f59889 | FIP 容器打包 |
| licheerv-nano-build-vendor | d4003f15 | FSBL（vendor TF-A）、blob |
| aic8800-vendor | d4003f15 | Wi-Fi 6 / BT SDIO 驱动 |
| cvitek-tpu-vendor | d4003f15 | TPU 内核驱动 |

用户态 TPU 栈（cviruntime、cvikernel、cvibuilder、cnpy、zlib、
tpu-mlir 容器、基准测试套件）不在本仓库内，单独维护。

## 快速开始

主机环境为 Debian 13 amd64（或兼容系统），debootstrap 和镜像打包需要
root 权限。

```sh
apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
  device-tree-compiler u-boot-tools build-essential bc bison flex \
  libssl-dev libelf-dev libncurses-dev python3 parted dosfstools rsync \
  debootstrap qemu-user-static binfmt-support git

git clone <本仓库> && cd licheervnano
make rootfs        # debootstrap Debian 13 + 软件包（约 5 分钟，需联网）
make image         # 完整构建：补丁、u-boot、opensbi、fsbl、内核、
                   # 模块、fip、SD 镜像打包
```

产物为 `images/licheervnano.img` 和 `images/licheervnano.img.gz`。
烧录：balenaEtcher 可直接使用 `.img.gz`，或者
`dd if=images/licheervnano.img of=/dev/sdX bs=4M conv=fsync`。

控制台为 UART0，115200 8N1。板型在启动时通过 U-Boot 的 extlinux 菜单
选择（默认 WE，超时数秒）。登录用户 root，密码 sipeed（可用
`ROOT_PASSWORD` 变量修改）。

单独执行各步骤请参考 `make help`。

## 仓库结构

| 目录 | 用途 |
|---|---|
| `manifest/` | 所有组件的 SHA 和 URL |
| `src/` | 源码快照（内核也克隆到这里） |
| `patches/` | 基于纯净快照的本地补丁（diff -u 格式） |
| `overlay/` | 构建时覆盖到快照上的新增文件 |
| `firmware/` | vendor blob 和自编译 FSBL（见 NOTICE.md） |
| `extlinux/` | 四种板型的启动菜单 |
| `scripts/` | refetch、usb-gadget、SSH 密钥处理 |
| `docs/` | 外设和构建指南 |
| `build/`、`rootfs/`、`images/` | 派生产物，已在 .gitignore 中 |

## 补丁与 overlay

`src/` 中的快照始终保持纯净。本地修改只存在于 `patches/`（对上游文件
的真实修改，严格使用 `diff -u` 格式，不含 index 行）和 `overlay/`
（新增文件）中。`make patches-apply` 将其应用到工作树，
`make patches-revert` 恢复纯净状态。应用结果用 `git status` 验证而非
退出码：在这种布局下 `git apply` 会静默跳过带 blob index 行的
`git diff` 格式补丁。

`make patches-check` 在先创建后修改的补丁链上会误报失败（补丁 0001
创建板级 DTS，后续补丁再修改它们）。真正的检查方式是在干净树上执行
`make patches-apply`。

## 更新组件版本

1. 更新 `manifest/sources.mk` 中的 SHA。
2. `make refetch COMP=<名称> SOURCE=upstream`。
3. 重新验证补丁（`make patches-apply`），构建，并在硬件上验证。
4. 将 `src/<名称>` 的变更与 manifest 一起提交为一个 commit。

## 外设

以下为 WE 板型上的状态，所列项目均已在开发板上验证。

| 外设 | 状态 | 文档 |
|---|---|---|
| UART、GPIO、pinmux | 可用 | [docs/uart_setup.md](docs/uart_setup.md)、[docs/gpio_setup.md](docs/gpio_setup.md) |
| 100M 以太网（E/WE） | 可用 | 内置 EPHY，ephy-init 补丁 |
| Wi-Fi 6 + BT 5（W/WE） | 可用 | [docs/wifi_setup.md](docs/wifi_setup.md) |
| USB gadget（ACM 控制台） | 可用 | [docs/usb_setup.md](docs/usb_setup.md) |
| 音频（麦克风 + 扬声器） | 可用 | [docs/audio_setup.md](docs/audio_setup.md) |
| TPU（0.5 TOPS INT8、BF16） | 可用 | [docs/tpu_sg2002.md](docs/tpu_sg2002.md) |
| RTC | 可用 | [docs/rtc_setup.md](docs/rtc_setup.md) |
| 看门狗 | 可用 | [docs/watchdog_setup.md](docs/watchdog_setup.md) |
| 温度传感器 | 可用 | [docs/thermal_setup.md](docs/thermal_setup.md) |
| LED、触发器 | 可用 | [docs/led_setup.md](docs/led_setup.md) |
| I2C、ADC | 可用 | [docs/i2c_setup.md](docs/i2c_setup.md)、[docs/adc_setup.md](docs/adc_setup.md) |
| SG2002 引脚映射 | 参考资料 | [docs/sg2002_pin_map.md](docs/sg2002_pin_map.md) |

显示（MIPI DSI）、摄像头（ISP）和视频编解码器（VPU）在主线栈中暂不
支持，这些属于闭源或工作量很大的 vendor 模块。

## TPU

板载 TPU 推理通过 vendor 驱动的 forward port（`soph_tpu.ko`，自动
编译）实现。本仓库只保留内核侧：驱动、`cvitek,tpu` DT 节点和
`CVITPU_GET_PADDR` ioctl 契约。用户态栈（运行时交叉编译、tpu-mlir
容器模型编译、基准测试套件、从 ONNX 到上板运行的完整流程）不在
本仓库内，单独维护。
TPU 模块概览见 [docs/tpu_sg2002.md](docs/tpu_sg2002.md)。
参考数据：mobilenet_v2 BF16 约 22 ms，yolov5s INT8（INT8 输入输出）
在 700 MHz 下约 77 ms。

## 许可证

项目自身的构建脚本等采用 MIT 许可证（见 LICENSE）。`src/` 中的每个
快照保留其上游许可证。二进制 blob 的来源和状态见
[NOTICE.md](NOTICE.md)。本仓库的主要文档语言为俄语，英文和中文 README
为翻译版本。
