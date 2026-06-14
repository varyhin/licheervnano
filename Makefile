# Сборочный Makefile проекта licheervnano (Sipeed LicheeRV Nano, SG2002, RISC-V).
# Делает всё от применения патчей до готового images/licheervnano.img.
#
# Источники компонентов: снапшоты в src/ этого репозитория (по умолчанию,
# сеть не нужна) либо официальные upstream по пинам manifest/sources.mk
# (make refetch COMP=<имя> SOURCE=upstream). Ядро linux в репозитории не
# хранится, его клонирует make fetch-linux (вызывается автоматически).
#
# Использование:
#   make                     полная сборка (= make image), требует root для losetup
#   make fetch-linux         клонировать ядро на пин манифеста
#   make patches-check       проверить что патчи применяются чисто
#   make refetch COMP=u-boot SOURCE=upstream   перекачать src/<comp> из upstream
#   make uboot opensbi ...   отдельные шаги (см. make help)
#   make clean               rm -rf build/
#   make distclean           clean + revert src/<repo> (обнуляет состояние)
#
# Зависимости хоста: gcc-riscv64-linux-gnu, binutils-riscv64-linux-gnu,
# device-tree-compiler, u-boot-tools, build-essential, bc, bison, flex,
# libssl-dev, libelf-dev, libncurses-dev, python3, parted, dosfstools, rsync.

PROJ        := $(CURDIR)
CROSS       := riscv64-linux-gnu-
ARCH        := riscv
JOBS        := -j$(shell nproc)
KMAKE       := make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS)

include $(PROJ)/manifest/sources.mk

SRC_LINUX     := $(PROJ)/src/linux
SRC_UBOOT     := $(PROJ)/src/u-boot
SRC_OPENSBI   := $(PROJ)/src/opensbi
SRC_FSBL      := $(PROJ)/src/licheerv-nano-build-vendor
SRC_AIC_BSP   := $(PROJ)/src/aic8800-vendor/aic8800_bsp
SRC_AIC_FDRV  := $(PROJ)/src/aic8800-vendor/aic8800_fdrv
SRC_AIC_BTLPM := $(PROJ)/src/aic8800-vendor/aic8800_btlpm
SRC_CVITEK_TPU := $(PROJ)/src/cvitek-tpu-vendor

BUILD         := $(PROJ)/build
BUILD_UBOOT   := $(BUILD)/u-boot
BUILD_OPENSBI := $(BUILD)/opensbi
BUILD_FSBL    := $(BUILD)/fsbl
BUILD_LINUX   := $(BUILD)/linux

# Версия каталога модулей = KERNELRELEASE, который modules_install берёт
# из этого файла после сборки ядра. Ленивое =, на чистом дереве файла
# ещё нет; не использовать до цели kernel (иначе пусто, см. guard в рецептах).
KERNEL_VER = $(shell cat $(BUILD_LINUX)/include/config/kernel.release 2>/dev/null)

# Debian suite задаёт и путь ROOTFS, и параметр debootstrap ниже.
DEBIAN_SUITE := trixie

ROOTFS    := $(PROJ)/rootfs/$(DEBIAN_SUITE)
FIRMWARE  := $(PROJ)/firmware
IMAGES    := $(PROJ)/images

# debootstrap config (см. targets debootstrap / rootfs-packages / rootfs)
DEBIAN_MIRROR  := http://deb.debian.org/debian
ROOT_PASSWORD  ?= sipeed
TIMEZONE       ?= Europe/Moscow
LOCALE         ?= en_US.UTF-8
LOCALE_GEN     := en_US.UTF-8 UTF-8\n
QEMU_STATIC    := /usr/bin/qemu-riscv64-static
EXTRA_PKGS     := \
  bluez bluez-tools \
  iw wireless-regdb wpasupplicant isc-dhcp-client \
  openssh-server \
  curl wget git nano vim-tiny tmux htop tree less \
  i2c-tools gpiod busybox \
  tcpdump bind9-dnsutils mtr-tiny iperf3 \
  pciutils usbutils \
  ca-certificates gnupg \
  tzdata locales bash-completion \
  systemd-timesyncd util-linux-extra \
  alsa-utils

# patches (порядок применения важен)
PATCHES_UBOOT  := $(sort $(wildcard $(PROJ)/patches/uboot/*.patch))
PATCHES_FSBL   := $(sort $(wildcard $(PROJ)/patches/fsbl/*.patch))
PATCHES_LINUX  := $(sort $(wildcard $(PROJ)/patches/linux/*.patch))
PATCHES_AIC    := $(sort $(wildcard $(PROJ)/patches/aic8800-vendor/*.patch))
PATCHES_CVITEK_TPU := $(sort $(wildcard $(PROJ)/patches/cvitek-tpu-vendor/*.patch))

.PHONY: all help fetch-linux refetch patches-check patches-apply patches-revert \
        uboot opensbi fsbl kernel aic8800 aic8800-install \
        soph_tpu soph_tpu-install \
        fip image clean distclean \
        debootstrap rootfs-packages rootfs _check_debootstrap_host \
        usb-gadget-install

all: image

help:
	@echo "Targets:"
	@echo "  all              = image (full build, требует root)"
	@echo "  fetch-linux      клонировать src/linux на пин манифеста (авто-зависимость)"
	@echo "  refetch          перекачать src/<COMP> из upstream: COMP=<имя> SOURCE=upstream"
	@echo "                   после перекачки пустой git status = снапшот без дрейфа"
	@echo "  patches-check    git apply --check всех patches/"
	@echo "  patches-apply    git apply всех patches/ + overlay на src/<repo>"
	@echo "  patches-revert   revert src/<repo> + удалить patch-created/overlay файлы"
	@echo "  uboot            собрать u-boot.bin + u-boot.dtb"
	@echo "  opensbi          собрать fw_dynamic.bin (нужен u-boot.dtb)"
	@echo "  fsbl             собрать BL2, копировать в firmware/cv181x.bin"
	@echo "  kernel           собрать Image + dtbs + modules + modules_install"
	@echo "  aic8800          собрать bsp.ko + fdrv.ko + btlpm.ko"
	@echo "  aic8800-install  install aic8800 modules в rootfs + depmod"
	@echo "  soph_tpu         собрать soph_tpu.ko (vendor TPU, форвард-порт)"
	@echo "  soph_tpu-install install soph_tpu.ko в rootfs + depmod"
	@echo "  fip              собрать images/fip.bin"
	@echo "  image            собрать images/licheervnano.img + .img.gz (требует root)"
	@echo "  clean            rm -rf build/"
	@echo "  distclean        clean + patches-revert"
	@echo "  debootstrap      создать rootfs/$(DEBIAN_SUITE) с нуля (требует root,"
	@echo "                   debootstrap, qemu-user-static; ~5 мин + интернет)"
	@echo "  rootfs-packages  apt install EXTRA_PKGS в существующий rootfs"
	@echo "                   через chroot (требует qemu-user-static + интернет)"
	@echo "  rootfs           debootstrap + rootfs-packages одной командой"
	@echo "                   используйте FORCE=1 для перезаписи существующего rootfs"
	@echo "  usb-gadget-install   разложить usb-gadget.service в rootfs (ACM console)"

# Ядро это единственный компонент без снапшота в репо. Клонируется shallow
# на тег манифеста, HEAD сверяется с пином (расхождение = стоп).
fetch-linux:
	@if [ -d $(SRC_LINUX)/.git ]; then \
	  actual=$$(git -C $(SRC_LINUX) rev-parse HEAD); \
	  [ "$$actual" = "$(PIN_linux)" ] \
	    || { echo "src/linux HEAD $$actual не равен пину $(PIN_linux)"; exit 1; }; \
	else \
	  echo "==> fetch linux $(REF_linux)"; \
	  git clone --depth 1 --branch $(REF_linux) $(URL_linux) $(SRC_LINUX); \
	  actual=$$(git -C $(SRC_LINUX) rev-parse HEAD); \
	  [ "$$actual" = "$(PIN_linux)" ] \
	    || { echo "клон дал $$actual, ожидался пин $(PIN_linux)"; exit 1; }; \
	fi

# Перекачка снапшота из официального upstream (второй источник компонента).
# Пример: make refetch COMP=u-boot SOURCE=upstream
refetch:
	@test -n "$(COMP)" || { echo "использование: make refetch COMP=<имя> SOURCE=upstream"; exit 1; }
	@test "$(SOURCE)" = "upstream" \
	  || { echo "источник по умолчанию это снапшот в src/; перекачка только SOURCE=upstream"; exit 1; }
	@test -n "$(URL_$(COMP))" || { echo "компонент $(COMP) не описан в manifest/sources.mk"; exit 1; }
	$(PROJ)/scripts/refetch.sh "$(COMP)" "$(URL_$(COMP))" "$(PIN_$(COMP))" \
	  "$(EXCLUDE_$(COMP))" $(SUBPATH_$(COMP))

# ВНИМАНИЕ: --check всех linux-патчей разом ложно падает на цепочке
# create-затем-modify (0001 создаёт board-DTS, поздние патчи их меняют).
# Реальная проверка применимости это make patches-apply на чистом дереве.
patches-check: fetch-linux
	@echo "==> patches-check"
	cd $(SRC_UBOOT)   && git apply --check $(PATCHES_UBOOT)
	cd $(SRC_FSBL)    && git apply --check $(PATCHES_FSBL)
	cd $(SRC_LINUX)   && git apply --check $(PATCHES_LINUX)
	cd $(SRC_AIC_BSP)/.. && git apply --check $(PATCHES_AIC)
	cd $(SRC_CVITEK_TPU) && git apply --check $(PATCHES_CVITEK_TPU)

# Применение проверять по git status, не по exit code: git apply молча
# пропускает патчи формата git diff (index-строки), наши патчи поэтому
# строго diff -u. overlay/<comp>/ копируется поверх src/<comp> (новые
# файлы порта, не входящие в патчи).
patches-apply: fetch-linux
	@echo "==> patches-apply"
	cd $(SRC_UBOOT)   && git apply $(PATCHES_UBOOT)
	cd $(SRC_FSBL)    && git apply $(PATCHES_FSBL)
	cd $(SRC_LINUX)   && git apply $(PATCHES_LINUX)
	cd $(SRC_AIC_BSP)/.. && git apply $(PATCHES_AIC)
	cd $(SRC_CVITEK_TPU) && git apply $(PATCHES_CVITEK_TPU)
	cp -a $(PROJ)/overlay/cvitek-tpu-vendor/. $(SRC_CVITEK_TPU)/

patches-revert:
	@echo "==> patches-revert"
	cd $(PROJ) && git checkout HEAD -- \
	  src/u-boot src/licheerv-nano-build-vendor src/aic8800-vendor \
	  src/cvitek-tpu-vendor
	cd $(PROJ) && git clean -qfdx \
	  src/u-boot src/licheerv-nano-build-vendor src/aic8800-vendor \
	  src/cvitek-tpu-vendor
	@if [ -d $(SRC_LINUX)/.git ]; then \
	  git -C $(SRC_LINUX) checkout -q -- . && git -C $(SRC_LINUX) clean -qfd; \
	fi

uboot:
	@echo "==> uboot"
	rm -rf $(BUILD_UBOOT)
	$(KMAKE) -C $(SRC_UBOOT) O=$(BUILD_UBOOT) sipeed_licheerv_nano_defconfig
	$(KMAKE) -C $(SRC_UBOOT) O=$(BUILD_UBOOT) $(JOBS)

opensbi:
	@echo "==> opensbi (требует u-boot.dtb)"
	rm -rf $(BUILD_OPENSBI)
	$(KMAKE) -C $(SRC_OPENSBI) PLATFORM=generic \
	  FW_FDT_PATH=$(BUILD_UBOOT)/u-boot.dtb \
	  O=$(BUILD_OPENSBI) $(JOBS)

# В FSBL вшиваются git-SHA репо (fsbl/Makefile:64) и дата сборки
# (make_helpers/build_macros.mk:218). Обе строки зафиксированы константами
# той же длины, иначе firmware/cv181x.bin дрейфует байтами строки версии
# при каждой пересборке.
fsbl:
	@echo "==> fsbl (BL2 vendor TF-A)"
	mkdir -p $(SRC_FSBL)/fsbl/build
	python3 $(SRC_FSBL)/build/scripts/mmap_conv.py --type h \
	  $(SRC_FSBL)/build/boards/sg200x/sg2002_licheervnano_sd/memmap.py \
	  $(SRC_FSBL)/fsbl/build/cvi_board_memmap.h
	rm -rf $(BUILD_FSBL)
	make -C $(SRC_FSBL)/fsbl bl2 \
	  CHIP_ARCH=cv181x ARCH=$(ARCH) BOOT_CPU=$(ARCH) \
	  CROSS_COMPILE_GLIBC_RISCV64=$(CROSS) \
	  DDR_CFG=ddr3_1866_x16 TPU_PERF_MODE=y OD_CLK_SEL=y \
	  BUILD_STRING=reproducible-bld \
	  BUILD_MESSAGE_TIMESTAMP='"0000-00-00T00:00:00+00:00"' \
	  O=$(BUILD_FSBL) $(JOBS)
	cp $(BUILD_FSBL)/bl2.bin $(FIRMWARE)/cv181x.bin

kernel: fetch-linux
	@echo "==> kernel + dtbs + modules + modules_install"
	rm -rf $(BUILD_LINUX)
	$(KMAKE) -C $(SRC_LINUX) O=$(BUILD_LINUX) defconfig
	@# src/linux это собственный git-клон с применёнными патчами (dirty),
	@# setlocalversion давал бы 6.18.29-dirty. Версия фиксируется ровно
	@# 6.18.29: AUTO off + пустой LOCALVERSION в окружении (гасит «+»).
	cd $(SRC_LINUX) && scripts/config --file $(BUILD_LINUX)/.config \
	  --disable LOCALVERSION_AUTO \
	  --module CFG80211 --module MAC80211 --module RFKILL --enable WLAN \
	  --enable CV1800B_EPHY_INIT --module MDIO_BUS_MUX_MMIOREG \
	  --module BT --enable BT_BREDR --enable BT_LE \
	  --module BT_HCIBTSDIO --module BT_RFCOMM --enable BT_RFCOMM_TTY \
	  --module BT_BNEP --enable BT_BNEP_MC_FILTER --enable BT_BNEP_PROTO_FILTER \
	  --module BT_HIDP \
	  --module SOPHGO_CV1800B_ADC \
	  --module SOPHGO_CV1800_RTCSYS --module RTC_DRV_CV1800 \
	  --module DW_WATCHDOG --enable WATCHDOG_SYSFS \
	  --module CV1800_THERMAL \
	  --enable NEW_LEDS --enable LEDS_CLASS \
	  --module LEDS_GPIO --enable LEDS_TRIGGERS \
	  --enable LEDS_TRIGGER_DISK --enable LEDS_TRIGGER_HEARTBEAT \
	  --enable LEDS_TRIGGER_DEFAULT_ON \
	  --enable LEDS_TRIGGER_NETDEV --enable LEDS_TRIGGER_PANIC \
	  --enable LEDS_TRIGGER_ACTIVITY --enable LEDS_TRIGGER_CPU \
	  --module LEDS_USER \
	  --module USB_DWC2 --enable USB_DWC2_DUAL_ROLE \
	  --module SND --module SND_SOC \
	  --module SND_SOC_CV1800B_TDM \
	  --module SND_SOC_CV1800B_ADC_CODEC \
	  --module SND_SOC_CV1800B_DAC_CODEC \
	  --module SND_SOC_SIMPLE_CARD \
	  --module SOPHGO_CV1800B_DMAMUX \
	  --enable USB_GADGET --module USB_LIBCOMPOSITE \
	  --module USB_CONFIGFS \
	  --enable USB_CONFIGFS_SERIAL \
	  --enable USB_CONFIGFS_ACM \
	  --enable USB_CONFIGFS_NCM \
	  --enable USB_CONFIGFS_RNDIS \
	  --enable USB_CONFIGFS_ECM \
	  --enable USB_U_SERIAL --enable USB_U_ETHER \
	  --enable USB_F_ACM --enable USB_F_NCM \
	  --enable USB_F_RNDIS --enable USB_F_ECM \
	  --enable CMA --enable DMA_CMA \
	  --enable CMA_SIZE_SEL_MBYTES --set-val CMA_SIZE_MBYTES 64 \
	  --enable DMABUF_HEAPS --enable DMABUF_HEAPS_SYSTEM --enable DMABUF_HEAPS_CMA
	$(KMAKE) -C $(SRC_LINUX) O=$(BUILD_LINUX) LOCALVERSION= olddefconfig
	$(KMAKE) -C $(SRC_LINUX) O=$(BUILD_LINUX) LOCALVERSION= $(JOBS) Image dtbs modules
	@test -n "$(KERNEL_VER)" || { echo "ERROR: KERNEL_VER пуст, ядро не собрано"; exit 1; }
	rm -rf $(ROOTFS)/lib/modules/$(KERNEL_VER)
	$(KMAKE) -C $(SRC_LINUX) O=$(BUILD_LINUX) \
	  INSTALL_MOD_PATH=$(ROOTFS) INSTALL_MOD_STRIP=1 modules_install

aic8800:
	@echo "==> aic8800 bsp + fdrv + btlpm"
	$(KMAKE) -C $(BUILD_LINUX) M=$(SRC_AIC_BSP) $(JOBS) modules
	$(KMAKE) -C $(BUILD_LINUX) M=$(SRC_AIC_FDRV) \
	  KBUILD_EXTRA_SYMBOLS=$(SRC_AIC_BSP)/Module.symvers \
	  $(JOBS) modules
	$(KMAKE) -C $(BUILD_LINUX) M=$(SRC_AIC_BTLPM) \
	  KBUILD_EXTRA_SYMBOLS=$(SRC_AIC_BSP)/Module.symvers \
	  $(JOBS) modules

# Pinmux I2C1/I2C3 и UART1/UART2 задаётся в board-DTS через pinctrl
# (patches/linux/0021), runtime devmem-сервисы удалены 2026-06-11.
# История: безусловный remux падов SD1 в I2C сервисом setup-i2c-pinmux
# отрезал SDIO Wi-Fi на W/WE.

# USB Gadget на DWC2: single-function ACM (console). RNDIS/NCM сняты как
# небезопасные для composite-энумерации на Windows.
# Скрипт и systemd-юнит копируются из scripts/ (под VCS, легко править).
# Также включается getty@ttyGS0 для login prompt на ACM console.
usb-gadget-install:
	@echo "==> usb-gadget-install"
	mkdir -p $(ROOTFS)/usr/local/sbin \
	         $(ROOTFS)/etc/systemd/system/multi-user.target.wants
	install -m 0755 $(PROJ)/scripts/setup-usb-gadget.sh \
	  $(ROOTFS)/usr/local/sbin/setup-usb-gadget.sh
	install -m 0644 $(PROJ)/scripts/usb-gadget.service \
	  $(ROOTFS)/etc/systemd/system/usb-gadget.service
	chroot $(ROOTFS) ln -sf /etc/systemd/system/usb-gadget.service \
	  /etc/systemd/system/multi-user.target.wants/usb-gadget.service
	@# serial-getty@ttyGS0.service запускается из setup-usb-gadget.sh
	@# после фактического появления /dev/ttyGS0, поэтому в targets.wants
	@# не добавляем (ConditionPathExists скипнул бы сервис на boot,
	@# когда tty ещё не существует).

aic8800-install: aic8800
	@echo "==> aic8800-install (rootfs + depmod + modprobe.d)"
	@test -n "$(KERNEL_VER)" || { echo "ERROR: KERNEL_VER пуст, сначала make kernel"; exit 1; }
	mkdir -p $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra/aic8800
	cp $(SRC_AIC_BSP)/aic8800_bsp.ko \
	   $(SRC_AIC_FDRV)/aic8800_fdrv.ko \
	   $(SRC_AIC_BTLPM)/aic8800_btlpm.ko \
	   $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra/aic8800/
	$(CROSS)strip --strip-debug $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra/aic8800/*.ko
	depmod -a -b $(ROOTFS) $(KERNEL_VER)
	@# Прошивка чипа AIC8801 U03 (модуль Sipeed AIC8800D80; комплект u03
	@# + fmacfw/fmacfwbt + userconfig).
	@# Путь зашит дефолтом CONFIG_AIC_FW_PATH в aic8800_bsp/Makefile.
	@# Без этих файлов fdrv падает на request_firmware и wlan0 не создаётся.
	mkdir -p $(ROOTFS)/usr/lib/firmware/aic8800_sdio/aic8800_and_aic8800D80
	cp $(FIRMWARE)/aic8800_u03/* \
	   $(ROOTFS)/usr/lib/firmware/aic8800_sdio/aic8800_and_aic8800D80/
	mkdir -p $(ROOTFS)/etc/modprobe.d
	echo "# AIC8800 fdrv debug level: 3 = LOGERROR(1)|LOGINFO(2)" \
	  > $(ROOTFS)/etc/modprobe.d/aic8800.conf
	echo "# (4=LOGTRACE 8=LOGDEBUG 0x400=LOGFW) изменить runtime через" \
	  >> $(ROOTFS)/etc/modprobe.d/aic8800.conf
	echo "# echo N > /sys/module/aic8800_fdrv/parameters/aicwf_dbg_level" \
	  >> $(ROOTFS)/etc/modprobe.d/aic8800.conf
	echo "options aic8800_fdrv aicwf_dbg_level=3" \
	  >> $(ROOTFS)/etc/modprobe.d/aic8800.conf
	@# ps_on=0 отключает powersave прошивки чипа (через me_config).
	@# С ps_on=1 (дефолт) idle-чип уходит в doze и перестаёт отвечать:
	@# flow-ctrl кредиты -1, wakeup-запись в reg 0x09 фейлится, cmd queue
	@# crashed; лечится только холодным power cycle (железо W 2026-06-11).
	@# Host-side сон (CONFIG_SDIO_PWRCTRL) уже выключен в Makefile vendor.
	echo "options aic8800_fdrv ps_on=0" \
	  >> $(ROOTFS)/etc/modprobe.d/aic8800.conf

# Форвард-портнутый vendor TPU driver (soph_tpu, cv181x "mars").
# Узел DT cvitek,tpu в patches/linux/0017. Драйвер требует patches-apply
# (pristine src/cvitek-tpu-vendor + патч 0001 + overlay/cvitek-tpu-vendor).
soph_tpu:
	@echo "==> soph_tpu (vendor TPU driver, форвард-порт 6.18)"
	$(KMAKE) -C $(BUILD_LINUX) M=$(SRC_CVITEK_TPU) $(JOBS) modules

soph_tpu-install: soph_tpu
	@echo "==> soph_tpu-install (rootfs + depmod)"
	@test -n "$(KERNEL_VER)" || { echo "ERROR: KERNEL_VER пуст, сначала make kernel"; exit 1; }
	mkdir -p $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra
	cp $(SRC_CVITEK_TPU)/soph_tpu.ko $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra/
	$(CROSS)strip --strip-debug $(ROOTFS)/lib/modules/$(KERNEL_VER)/extra/soph_tpu.ko
	depmod -a -b $(ROOTFS) $(KERNEL_VER)

fip:
	@echo "==> fip container"
	rm -f $(IMAGES)/fip.bin
	mkdir -p $(IMAGES)
	python3 $(PROJ)/src/fiptool/fiptool \
	  --fsbl       $(FIRMWARE)/cv181x.bin \
	  --ddr_param  $(FIRMWARE)/ddr_param.bin \
	  --rtos       $(FIRMWARE)/cvirtos.bin \
	  --opensbi    $(BUILD_OPENSBI)/platform/generic/firmware/fw_dynamic.bin \
	  --uboot      $(BUILD_UBOOT)/u-boot.bin \
	  $(IMAGES)/fip.bin

image:
	@echo "==> SD image (требует root для losetup/mount)"
	@if [ $$(id -u) -ne 0 ]; then echo "make image требует root"; exit 1; fi
	$(MAKE) patches-revert
	$(MAKE) patches-apply
	$(MAKE) uboot
	$(MAKE) opensbi
	$(MAKE) fsbl
	$(MAKE) kernel
	$(MAKE) aic8800-install
	$(MAKE) soph_tpu-install
	$(MAKE) fip
	$(MAKE) _image_pack
	$(MAKE) _image_gz

# Гигиена клонируемого образа: identity ОС (machine-id, dbus machine-id,
# SSH host-ключи, random-seed) вычищается из p2 при упаковке и генерируется
# заново на первом boot каждой карты (machine-id пишет systemd, ключи
# scripts/regenerate-ssh-host-keys.service). rootfs/trixie не трогается.
_image_pack:
	@echo "==> SD image pack"
	rm -f $(IMAGES)/licheervnano.img
	mkdir -p $(IMAGES)
	truncate -s 2048M $(IMAGES)/licheervnano.img
	parted -s $(IMAGES)/licheervnano.img mklabel msdos
	parted -s $(IMAGES)/licheervnano.img mkpart primary fat16 1MiB  132MiB
	parted -s $(IMAGES)/licheervnano.img mkpart primary ext4  132MiB 100%
	parted -s $(IMAGES)/licheervnano.img set 1 boot on
	LOOP=$$(losetup -fP --show $(IMAGES)/licheervnano.img); \
	partprobe $${LOOP} || true; \
	udevadm settle --timeout=10 || true; \
	for i in 1 2 3 4 5 6; do \
	  [ -b $${LOOP}p1 ] && [ -b $${LOOP}p2 ] && break; \
	  partprobe $${LOOP} || true; udevadm settle --timeout=3 || true; \
	done; \
	[ -b $${LOOP}p1 ] || { echo "partition nodes $${LOOP}p1/p2 missing"; losetup -d $${LOOP}; exit 1; }; \
	mkfs.vfat -F 16 -n BOOT  $${LOOP}p1 >/dev/null; \
	mkfs.ext4 -F   -L root   $${LOOP}p2 >/dev/null 2>&1; \
	mkdir -p /tmp/sd-boot /tmp/sd-root; \
	mount $${LOOP}p1 /tmp/sd-boot; \
	mount $${LOOP}p2 /tmp/sd-root; \
	cp $(IMAGES)/fip.bin /tmp/sd-boot/; \
	cp $(BUILD_LINUX)/arch/riscv/boot/Image /tmp/sd-boot/; \
	cp $(BUILD_LINUX)/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-b.dtb /tmp/sd-boot/; \
	cp $(BUILD_LINUX)/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-e.dtb /tmp/sd-boot/; \
	cp $(BUILD_LINUX)/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-w.dtb /tmp/sd-boot/; \
	cp $(BUILD_LINUX)/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-we.dtb /tmp/sd-boot/; \
	mkdir -p /tmp/sd-boot/extlinux; \
	cp $(PROJ)/extlinux/extlinux.conf /tmp/sd-boot/extlinux/; \
	rsync -aHAX --numeric-ids --one-file-system $(ROOTFS)/ /tmp/sd-root/; \
	: > /tmp/sd-root/etc/machine-id; \
	rm -f /tmp/sd-root/var/lib/dbus/machine-id; \
	rm -f /tmp/sd-root/var/lib/systemd/random-seed; \
	rm -f /tmp/sd-root/etc/ssh/ssh_host_*; \
	echo "licheervnano $$(git -C $(PROJ) rev-parse --short HEAD) $$(date -u +%FT%TZ)" > /tmp/sd-root/etc/licheervnano-release; \
	install -m 644 $(PROJ)/scripts/regenerate-ssh-host-keys.service /tmp/sd-root/etc/systemd/system/; \
	mkdir -p /tmp/sd-root/etc/systemd/system/multi-user.target.wants; \
	ln -sf ../regenerate-ssh-host-keys.service /tmp/sd-root/etc/systemd/system/multi-user.target.wants/regenerate-ssh-host-keys.service; \
	sync; \
	umount /tmp/sd-boot /tmp/sd-root; \
	losetup -d $${LOOP}; \
	rmdir /tmp/sd-boot /tmp/sd-root

# Сжатие готового образа в .gz для прошивки balenaEtcher (Etcher и 7-Zip
# понимают .gz нативно). Уровень -1: образ почти весь нули (жмётся быстро),
# реальные данные это rootfs. Оригинальный .img сохраняется (-k) для
# losetup/инспекции. Вызывается в конце image, отдельно: make _image_gz.
_image_gz:
	@echo "==> gzip образа в .gz для прошивки"
	gzip -1 -k -f $(IMAGES)/licheervnano.img
	@ls -la $(IMAGES)/licheervnano.img.gz

clean:
	@echo "==> clean"
	rm -rf $(BUILD)

distclean: clean patches-revert
	@echo "==> distclean done"

_check_debootstrap_host:
	@command -v debootstrap >/dev/null 2>&1 \
	  || { echo "Install: apt install debootstrap"; exit 1; }
	@[ -x $(QEMU_STATIC) ] \
	  || { echo "Install: apt install qemu-user-static binfmt-support"; exit 1; }
	@if [ $$(id -u) -ne 0 ]; then echo "debootstrap требует root"; exit 1; fi

debootstrap: _check_debootstrap_host
	@echo "==> debootstrap $(DEBIAN_SUITE) riscv64"
	@if [ -d $(ROOTFS) ] && [ -z "$$FORCE" ]; then \
	  echo "$(ROOTFS) уже существует. Используйте FORCE=1 для перезаписи."; \
	  exit 1; \
	fi
	rm -rf $(ROOTFS)
	mkdir -p $(ROOTFS)
	debootstrap --foreign --arch=riscv64 \
	  $(DEBIAN_SUITE) $(ROOTFS) $(DEBIAN_MIRROR)
	cp $(QEMU_STATIC) $(ROOTFS)/usr/bin/
	chroot $(ROOTFS) /debootstrap/debootstrap --second-stage
	echo licheervnano > $(ROOTFS)/etc/hostname
	printf '127.0.0.1\tlocalhost\n127.0.1.1\tlicheervnano\n' > $(ROOTFS)/etc/hosts
	echo "deb $(DEBIAN_MIRROR) $(DEBIAN_SUITE) main contrib non-free non-free-firmware" \
	  > $(ROOTFS)/etc/apt/sources.list
	chroot $(ROOTFS) /bin/sh -c "echo 'root:$(ROOT_PASSWORD)' | chpasswd"
	echo "$(TIMEZONE)" > $(ROOTFS)/etc/timezone
	chroot $(ROOTFS) ln -sf /usr/share/zoneinfo/$(TIMEZONE) /etc/localtime
	chroot $(ROOTFS) ln -sf /lib/systemd/system/serial-getty@.service \
	  /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
	mkdir -p $(ROOTFS)/etc/network/interfaces.d
	printf 'auto lo\niface lo inet loopback\n' \
	  > $(ROOTFS)/etc/network/interfaces.d/lo
	printf 'auto end0\nallow-hotplug end0\niface end0 inet dhcp\n' \
	  > $(ROOTFS)/etc/network/interfaces.d/end0
	$(MAKE) usb-gadget-install
	@# Автозагрузка i2c-dev для /dev/i2c-N chardev
	mkdir -p $(ROOTFS)/etc/modules-load.d
	echo "i2c-dev" > $(ROOTFS)/etc/modules-load.d/i2c-dev.conf
	rm -f $(ROOTFS)/usr/bin/qemu-riscv64-static
	@echo "==> debootstrap done, root password: $(ROOT_PASSWORD)"

rootfs-packages: _check_debootstrap_host
	@echo "==> rootfs-packages (chroot+apt в существующий rootfs)"
	@[ -d $(ROOTFS) ] \
	  || { echo "$(ROOTFS) не существует, сделайте 'make debootstrap'"; exit 1; }
	cp $(QEMU_STATIC) $(ROOTFS)/usr/bin/
	cp /etc/resolv.conf $(ROOTFS)/etc/resolv.conf
	mount --bind /proc $(ROOTFS)/proc
	mount --bind /sys $(ROOTFS)/sys
	mount --bind /dev $(ROOTFS)/dev
	-chroot $(ROOTFS) env DEBIAN_FRONTEND=noninteractive \
	  /usr/bin/apt-get update
	-chroot $(ROOTFS) env DEBIAN_FRONTEND=noninteractive \
	  /usr/bin/apt-get install -y --no-install-recommends $(EXTRA_PKGS)
	@# Разрешить ssh root login (default prohibit-password требует key)
	sed -i '/^#PermitRootLogin prohibit-password/a PermitRootLogin yes' \
	  $(ROOTFS)/etc/ssh/sshd_config
	@# Генерация локалей (en_US.UTF-8 default + ru_RU.UTF-8 доступна)
	printf '$(LOCALE_GEN)' >> $(ROOTFS)/etc/locale.gen
	-chroot $(ROOTFS) /usr/sbin/locale-gen
	chroot $(ROOTFS) /usr/sbin/update-locale LANG=$(LOCALE)
	-chroot $(ROOTFS) /usr/bin/apt-get clean
	umount $(ROOTFS)/dev $(ROOTFS)/sys $(ROOTFS)/proc || true
	rm -f $(ROOTFS)/usr/bin/qemu-riscv64-static
	rm -f $(ROOTFS)/etc/resolv.conf
	@# Таймкипинг через аппаратный RTC (sophgo,cv1800b-rtc, /dev/rtc0,
	@# RTC_HCTOSYS) + systemd-timesyncd по NTP. fake-hwclock убран как
	@# избыточный (RTC держит время через warm-reboot, NTP правит на сети).
	@echo "==> rootfs-packages done (LANG=$(LOCALE))"

rootfs: debootstrap rootfs-packages
	@echo "==> rootfs full setup done"
