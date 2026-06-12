# USB OTG (DWC2)

USB 2.0 контроллер SoC SG2002 это DesignWare DWC2 (HS, 480 Mbps). На плате LicheeRV Nano выведен в Type-C коннектор, через который также подаётся питание 5 В.

Статус: ACM-gadget console работает в образе из коробки (см. раздел
«Реализация в проекте»), host-режим через OTG-переходник.

## Параметры контроллера

| Параметр | Значение | Источник |
|---|---|---|
| MMIO base | `0x04340000`, длина `0x10000` | SG2002 TRM v1.0-alpha |
| IRQ (главный процессор) | 30 (PLIC), в DTS `SOC_PERIPHERAL_IRQ(14)` | TRM, кросс-сверка с архивом Sipeed |
| Тактирование | `CLK_AXI4_USB`, `CLK_APB_USB`, `CLK_USB_125M`, `CLK_USB_33K`, `CLK_USB_12M` | cv180x clock IDs |
| Reset | `RST_USB` | cv180x reset IDs |
| PHY | UTMI+ внутренний | TRM |
| Скорость | High-Speed (480 Mbps) | DWC2 + UTMI |
| Линий питания | 5V только Type-C, ID-pin нет | схема Sipeed |

## DT-узел

Добавлен в `cv180x.dtsi` патчем `patches/linux/0007-licheerv-nano-usb-dwc2.patch`, активируется во всех 4 board-DTS:

```
&usb { status = "okay"; };
```

Параметры узла:

```
compatible = "snps,dwc2";
reg = <0x4340000 0x10000>;
interrupts = <SOC_PERIPHERAL_IRQ(14) IRQ_TYPE_LEVEL_HIGH>;
phy_type = "utmi";
g-rx-fifo-size = <520>;
g-np-tx-fifo-size = <128>;
g-tx-fifo-size = <256 256 64 64 64 32 32 32>;
dr_mode = "otg";
```

## dr_mode в device tree

| Значение | Поведение |
|---|---|
| `host` | только Host, контроллер видит подключаемые USB-устройства |
| `peripheral` | только Device/Gadget, плата подключается к ПК как USB-устройство |
| `otg` | Dual-Role, роль определяется по VBUS/ID (текущий выбор) |

Сейчас `otg`. Драйвер DWC2 в host-режиме создаст root-hub `usb1`, в peripheral создаст `/sys/class/udc/4340000.usb`. На LicheeRV Nano ID-pin отсутствует, distinction по VBUS sense.

Альтернативы без пересборки DTB:

- Override через cmdline в `extlinux/extlinux.conf`: добавить `dwc2.dr_mode=host` или `dwc2.dr_mode=peripheral`.
- Sysfs role-switch (если ядро экспортирует): `echo host > /sys/bus/platform/devices/4340000.usb/role`.

## Kernel config

`CONFIG_USB_DWC2=m`, `CONFIG_USB_DWC2_DUAL_ROLE=y` (см. Makefile, цель `kernel`). Модуль `dwc2.ko` лежит в `/lib/modules/6.18.29/kernel/drivers/usb/dwc2/dwc2.ko`. Автозагрузка через udev по DT compatible match `snps,dwc2`.

Gadget-функции это отдельный набор опций, см. раздел «USB Gadget mode» ниже.

## Диагностика после boot

```
lsmod | grep dwc2
# dwc2  ...

dmesg | grep -i -E "dwc2|usb@4340000"
# ожидаем: dwc2 4340000.usb: ...
#         dwc2 4340000.usb: Configuration of DMA failed/OK
#         dwc2 4340000.usb: DWC OTG Controller
#         dwc2 4340000.usb: new USB bus number N

# Платформенный узел probed
ls /sys/bus/platform/devices/4340000.usb 2>/dev/null

# Текущая роль (если экспортируется)
cat /sys/bus/platform/devices/4340000.usb/of_node/dr_mode

# Host-сторона
ls /sys/bus/usb/devices/
# usb1 это root-hub, появится только если контроллер встал в host

# Peripheral-сторона
ls /sys/class/udc/
# 4340000.usb если контроллер встал в device
```

Тест host. Подключить USB-A адаптер к Type-C порту, вставить USB-флешку. В `dmesg` ожидается обнаружение нового устройства, в `/sys/bus/usb/devices/` появится новая запись `1-1`.

Тест peripheral. Подключить плату Type-C кабелем к ПК. На ПК в `dmesg` появится новое USB-устройство (без функции gadget оно пустое, нужен gadget-driver).

## USB Gadget mode

DWC2 в `otg` или `peripheral` режиме это половина истории. Контроллер готов работать как USB-устройство (`/sys/class/udc/4340000.usb` виден), но в ядре должна быть хотя бы одна gadget-функция, которая описывает что именно плата эмулирует при подключении к хосту. Без gadget-функции хост видит «пустое» устройство.

### Зачем это нужно на LicheeRV Nano

Type-C порт на плате это одновременно питание и USB. Если плата работает как gadget, то одним кабелем к ПК получаем:

- Console-over-USB (ACM функция). Плата это `/dev/ttyACM0` на ПК, на плате это `/dev/ttyGS0`. `serial-getty@ttyGS0` даёт login prompt без UART-конвертера.
- USB Ethernet (RNDIS/NCM/ECM). Плата это сетевой интерфейс на ПК, на плате это `usb0`. Полноценный SSH/scp без Wi-Fi и без RJ45 (особенно ценно для варианта B без сети).
- Mass storage. Плата это «флешка» для ПК, backing-store это файл-образ или blockdev на плате.
- HID, UVC, MIDI, FunctionFS это специализированные сценарии.

### configfs vs legacy

Два способа поднять gadget:

| Подход | Описание | Когда применять |
|---|---|---|
| Legacy (`g_serial`, `g_mass_storage`, ...) | Монолитные модули. Загрузил это устройство появилось у хоста. Один модуль это одно фиксированное устройство. | Быстрый разовый тест. |
| configfs (`libcomposite` + `usb_f_*`) | Каркас + независимые «функции-кирпичики». Конфигурация собирается в runtime через `/sys/kernel/config/usb_gadget/`. Можно склеить composite-устройство (например ACM + RNDIS + Mass-Storage одновременно). | Production и любой нетривиальный сценарий. |

В mainline новые устройства строят на configfs, legacy оставлен только для совместимости.

### Доступные функции

| Функция | Kconfig | Что эмулирует |
|---|---|---|
| ACM | `CONFIG_USB_CONFIGFS_ACM` | Виртуальный COM-порт, на плате `/dev/ttyGS0`, на ПК `/dev/ttyACM0` |
| RNDIS | `CONFIG_USB_CONFIGFS_RNDIS` | Ethernet через USB (Windows native) |
| ECM | `CONFIG_USB_CONFIGFS_ECM` | Ethernet через USB (Linux/macOS native) |
| NCM | `CONFIG_USB_CONFIGFS_NCM` | Ethernet через USB, более эффективный (Linux native, Windows 10+) |
| Mass Storage | `CONFIG_USB_CONFIGFS_MASS_STORAGE` | USB-флешка с backing-файлом |
| HID | `CONFIG_USB_CONFIGFS_F_HID` | Клавиатура, мышь, gamepad |
| UVC | `CONFIG_USB_CONFIGFS_F_UVC` | USB-видеокамера (для проброса CSI-камеры наружу) |
| MIDI | `CONFIG_USB_CONFIGFS_F_MIDI` | USB MIDI устройство |
| FunctionFS | `CONFIG_USB_CONFIGFS_F_FS` | Userspace-реализация любого USB-протокола (используется в adb) |
| ECM subset | `CONFIG_USB_CONFIGFS_ECM_SUBSET` | Урезанный ECM |

### Минимальный набор для bring-up

```
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=m
CONFIG_USB_CONFIGFS_SERIAL=y       # ACM
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_NCM=y          # Ethernet (Linux/Mac/Win10)
CONFIG_USB_CONFIGFS_RNDIS=y        # Ethernet (Windows legacy)
CONFIG_USB_CONFIGFS_ECM=y          # Ethernet (Linux/Mac fallback)
CONFIG_USB_CONFIGFS_MASS_STORAGE=y
CONFIG_USB_CONFIGFS_F_FS=y
```

В нашем kernel-конфиге эти опции включены, кроме `MASS_STORAGE` и `F_FS` (блок scripts/config цели `kernel` в Makefile).

### Пример настройки composite-устройства

После сборки и загрузки `libcomposite`:

```
modprobe libcomposite
mount -t configfs none /sys/kernel/config 2>/dev/null || true

cd /sys/kernel/config/usb_gadget/
mkdir g1
cd g1

echo 0x1d6b > idVendor    # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir strings/0x409
echo "0123456789ABCDEF" > strings/0x409/serialnumber
echo "Sipeed"            > strings/0x409/manufacturer
echo "LicheeRV Nano"     > strings/0x409/product

mkdir functions/acm.usb0
mkdir functions/rndis.usb0

mkdir configs/c.1
mkdir configs/c.1/strings/0x409
echo "ACM+RNDIS" > configs/c.1/strings/0x409/configuration
echo 250         > configs/c.1/MaxPower

ln -s functions/acm.usb0   configs/c.1/
ln -s functions/rndis.usb0 configs/c.1/

echo 4340000.usb > UDC    # активация gadget
```

После последней команды ПК видит составное устройство «COM-порт + сетевая карта». Чтобы отвязать, `echo "" > UDC`.

### Питание в gadget-режиме

В любом gadget-режиме (ACM, RNDIS, NCM, composite) плата это peripheral, поэтому:

- ПК подаёт 5V по VBUS Type-C, плата питается от этих 5V.
- Один кабель Type-C это и питание, и данные.
- Между ACM и RNDIS разницы по питанию нет, функция это логический слой поверх USB, на VBUS не влияет.

Декларация максимального потребления настраивается в configfs:

```
echo 250 > /sys/kernel/config/usb_gadget/g1/configs/c.1/MaxPower
```

250 mA это стандартное значение USB 2.0. ПК (особенно ноутбук на батарее) может ограничить порт меньшим током, в таком случае возможны просадки.

### Переключение между функциями

Подход 1 это composite (рекомендуется). Несколько функций живут в одной конфигурации одновременно:

```
ln -s functions/acm.usb0   configs/c.1/
ln -s functions/rndis.usb0 configs/c.1/
echo 4340000.usb > UDC
```

Хост видит составное устройство, на плате одновременно есть `/dev/ttyGS0` и `usb0`. Переключаться между функциями не нужно.

Подход 2 это runtime-смена через configfs (если функции взаимоисключающие):

```
# отвязать gadget
echo "" > /sys/kernel/config/usb_gadget/g1/UDC

# удалить старую функцию из конфигурации
rm /sys/kernel/config/usb_gadget/g1/configs/c.1/rndis.usb0
rmdir /sys/kernel/config/usb_gadget/g1/functions/rndis.usb0

# создать и привязать новую
mkdir /sys/kernel/config/usb_gadget/g1/functions/acm.usb0
ln -s /sys/kernel/config/usb_gadget/g1/functions/acm.usb0 \
      /sys/kernel/config/usb_gadget/g1/configs/c.1/

# поднять обратно
echo 4340000.usb > /sys/kernel/config/usb_gadget/g1/UDC
```

ПК видит «отключение и подключение» устройства, новая конфигурация поднимается за секунды. Удобно завернуть в `usb-mode-acm.sh` / `usb-mode-rndis.sh`.

Питание VBUS при `echo "" > UDC` не пропадает, плата продолжает работать.

### Systemd-сервис автозапуска

Упрощённый пример скрипта. Реальный скрипт проекта это
`scripts/setup-usb-gadget.sh`, он дополнительно ждёт появления UDC и
`/dev/ttyGS0` и запускает `serial-getty@ttyGS0`:

```sh
#!/bin/sh
set -e

GADGET=/sys/kernel/config/usb_gadget/g1

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
modprobe libcomposite

[ -d "$GADGET" ] && exit 0   # idempotent

mkdir -p "$GADGET"
cd "$GADGET"

echo 0x1d6b > idVendor      # Linux Foundation
echo 0x0104 > idProduct     # Multifunction Composite
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "Sipeed"        > strings/0x409/manufacturer
echo "LicheeRV Nano" > strings/0x409/product
echo "0001"          > strings/0x409/serialnumber

mkdir -p functions/acm.usb0

mkdir -p configs/c.1
mkdir -p configs/c.1/strings/0x409
echo "ACM" > configs/c.1/strings/0x409/configuration
echo 250   > configs/c.1/MaxPower

ln -s functions/acm.usb0 configs/c.1/

UDC=$(ls /sys/class/udc/ | head -n1)
echo "$UDC" > UDC
```

`/etc/systemd/system/usb-gadget.service`:

```
[Unit]
Description=USB Gadget (ACM)
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-usb-gadget.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
```

Активация:

```
systemctl enable usb-gadget.service
systemctl enable serial-getty@ttyGS0.service
```

После boot Type-C в ПК сразу даёт login prompt на `/dev/ttyACM0`. Для composite ACM+RNDIS+NCM скрипт расширяется добавлением `mkdir functions/rndis.usb0` + `ln -s`.

### Console-over-USB

После активации ACM на плате появляется `/dev/ttyGS0`. Поднять login prompt:

```
systemctl enable --now serial-getty@ttyGS0.service
```

На ПК это `/dev/ttyACM0` (Linux) или COM-порт (Windows). Подключение `screen /dev/ttyACM0 115200` это shell без UART-конвертера.

### USB Ethernet, типовая раскладка адресов

| Сторона | Интерфейс | Адрес |
|---|---|---|
| Плата | `usb0` | 192.168.7.2/24 |
| ПК | `enx*` (Linux), сетевой адаптер (Win/Mac) | 192.168.7.1/24 |

На плате назначать IP вручную или через `systemd-networkd` profile, на ПК через NetworkManager или вручную.

### Сводка

| Вопрос | Ответ |
|---|---|
| Питание в ACM/RNDIS | 5V от ПК по VBUS Type-C, разницы между функциями нет |
| ACM+RNDIS одновременно | Да, через composite (несколько функций в одной конфигурации) |
| Переключение runtime | `echo "" > UDC` + перелинковать функции + `echo udc > UDC` |
| ACM по умолчанию | systemd-юнит `usb-gadget.service` + `serial-getty@ttyGS0.service` |

### Риски и тонкости

- Type-C порт на плате один. В peripheral режиме нельзя одновременно работать как USB-host. Если нужен host (флешка через переходник), временно отвязать gadget: `echo "" > /sys/kernel/config/usb_gadget/g1/UDC`.
- При неправильном порядке команд (`UDC` записан до создания функций) gadget не активируется, ошибка возвращается в `echo`.
- На стороне ПК RNDIS видят все ОС, NCM лучше всех но Windows 10+, ECM это Linux/macOS. Для максимальной совместимости держать RNDIS + NCM/ECM в одном composite (хост сам выберет).
- ПК с ограничением порта по току (ноутбук на батарее, USB-хаб без питания) может вызвать просадку 5V. Видно по `dmesg` (warning о VBUS) или по нестабильному boot.

## Реализация в проекте

ACM-only single-function gadget с автозапуском при boot. Console-over-USB по одному Type-C кабелю, без USB Ethernet. Поднимается на всех 4 вариантах платы.

### Почему ACM-only

Изначально планировалось composite ACM+RNDIS+NCM (console + USB Ethernet). На железе пройдены три итерации:

| Итерация | Конфигурация | Что произошло |
|---|---|---|
| 1 | Multi-config (c.1=RNDIS+ACM Windows, c.2=NCM+ACM Linux) | Windows 10 видит device без MI_XX суффикса. Composite не распознан, только ACM как single-interface. |
| 2 | Single-config RNDIS+ACM | Composite распознан правильно. RNDIS interface в Error Code 28 (CM_PROB_FAILED_INSTALL), Windows 10 не имеет INF для нашего VID:PID. Microsoft deprecated RNDIS. |
| 3 | Single-config NCM+ACM | Composite распознан. NCM interface в Error Code 28. Windows 10 build 19045 не имеет `usbncm.inf` в DriverStore (опциональный driver, нет на этой системе). |
| 4 (финал) | Single-function ACM | Только COM-port, работает безусловно. |

USB Ethernet требует от Windows установки драйвера который часто отсутствует. Чистый ACM работает «из коробки» на любой Windows 7+, Linux, macOS. Если позже понадобится USB Ethernet, см. раздел «Расширение до USB Ethernet».

### Что включено в kernel

| Kconfig | Значение | Назначение |
|---|---|---|
| `USB_GADGET` | y | Core gadget framework (built-in для probe DWC2) |
| `USB_LIBCOMPOSITE` | m | Конструктор composite gadget |
| `USB_CONFIGFS` | m | configfs-интерфейс (`/sys/kernel/config/usb_gadget/`) |
| `USB_CONFIGFS_ACM` | y | Функция ACM (активна сейчас) |
| `USB_CONFIGFS_NCM` | y | Функция NCM (доступна, не используется) |
| `USB_CONFIGFS_RNDIS` | y | Функция RNDIS (доступна, не используется) |
| `USB_CONFIGFS_ECM` | y | Функция ECM (доступна, не используется) |
| `USB_F_ACM` | m | Модуль ACM |
| `USB_F_NCM` | m | Модуль NCM (built, не загружается) |
| `USB_F_RNDIS` | m | Модуль RNDIS (built, не загружается) |
| `USB_F_ECM` | m | Модуль ECM (built, не загружается) |
| `USB_U_SERIAL` | m | utility-модуль для serial gadget |
| `USB_U_ETHER` | m | utility-модуль для ethernet gadget |

Все опции включены в `Makefile` (цель `kernel`). Модули лежат в `/lib/modules/6.18.29/kernel/drivers/usb/gadget/`. Activated runtime через setup-скрипт. Network-функции в kernel остаются для возможности расширения без пересборки ядра.

### Файлы в rootfs

| Файл | Что делает |
|---|---|
| `/usr/local/sbin/setup-usb-gadget.sh` | Создаёт ACM gadget через configfs, активирует UDC, ждёт `/dev/ttyGS0`, запускает `serial-getty@ttyGS0` |
| `/etc/systemd/system/usb-gadget.service` | Oneshot-сервис, запускает скрипт после `local-fs.target` |
| `/etc/systemd/system/multi-user.target.wants/usb-gadget.service` | symlink автозапуска |

Source-файлы в `scripts/setup-usb-gadget.sh` и `scripts/usb-gadget.service`. Установка через `make usb-gadget-install` (вызывается автоматически из `make rootfs`).

### Конфигурация gadget

```
VID:PID           1d6b:0104 (Linux Foundation Multifunction Composite)
Manufacturer      Sipeed
Product           LicheeRV Nano
Serial            из /etc/machine-id (уникален на каждой плате)
Config c.1        ACM, MaxPower 250mA
```

Single-function: только `functions/acm.usb0` залинкована в `configs/c.1/`. `bDeviceClass` дефолтный (не IAD композит, так как функция одна).

### Что появляется после boot

На плате (через ~5-8 секунд от power-on):

```
# Модули загружены
lsmod | grep -E "libcomposite|usb_f_acm"

# Configfs-tree создан
ls /sys/kernel/config/usb_gadget/g1/

# UDC привязан
cat /sys/kernel/config/usb_gadget/g1/UDC
# 4340000.usb

# Виртуальный COM-port
ls /dev/ttyGS0

# systemd-сервис
systemctl status usb-gadget.service
# active (exited)

# Login prompt на ACM
systemctl status serial-getty@ttyGS0.service
# active (running)
```

На ПК после подключения Type-C кабеля:

**Linux:**
```
dmesg | tail
# usb X-Y: new high-speed USB device
# usb X-Y: Manufacturer: Sipeed
# usb X-Y: Product: LicheeRV Nano
# cdc_acm X-Y:2.1: ttyACM0: USB ACM device

ls /dev/ttyACM*
# /dev/ttyACM0
```

**Windows:**
```powershell
Get-PnpDevice | Where-Object {$_.InstanceId -match "VID_1D6B"} | Format-Table Status, Class, FriendlyName, InstanceId -AutoSize

# Status  Class FriendlyName                                          InstanceId
# ------  ----- ------------                                          ----------
# OK      USB   LicheeRV Nano                                         USB\VID_1D6B&PID_0104\<serial>
# OK      Ports Устройство с последовательным интерфейсом USB (COMx)  USB\VID_1D6B&PID_0104\<serial>
```

Оба entry со статусом OK. Номер COM-порта индивидуален на каждом ПК.

### Подключение к плате с ПК

#### Linux

```
# Console
screen /dev/ttyACM0 115200
# или minicom -D /dev/ttyACM0 -b 115200
# или picocom /dev/ttyACM0 -b 115200
# или tio /dev/ttyACM0 -b 115200
```

Если права закрыты, добавить пользователя в `dialout`:

```
sudo usermod -aG dialout $USER
# перелогиниться
```

#### Windows

Подключите Type-C. Windows автоматически распознаёт «Устройство с последовательным интерфейсом USB (COMx)». Номер COMx виден в:
- Device Manager → Ports (COM & LPT)
- PowerShell: `[System.IO.Ports.SerialPort]::GetPortNames()`

Terminal-emulator: PuTTY, TeraTerm, MobaXterm, Windows Terminal + plink.

В PuTTY:
- Connection type: Serial
- Serial line: `COMx`
- Speed: `115200`
- Open

#### macOS

```
screen /dev/cu.usbmodem* 115200
# или sudo cu -l /dev/cu.usbmodem* -s 115200
```

### Расширение до USB Ethernet

Если в будущем понадобится SSH/scp по Type-C, можно вернуть NCM или RNDIS функцию. Редактируем `scripts/setup-usb-gadget.sh`:

```sh
# Сменить single-function на composite (IAD descriptors)
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

# Добавить NCM (для Linux/Mac native, Win10+ с usbncm.inf)
mkdir -p functions/ncm.usb0
echo "02:11:22:33:44:55" > functions/ncm.usb0/host_addr
echo "02:11:22:33:44:56" > functions/ncm.usb0/dev_addr
ln -s functions/ncm.usb0 configs/c.1/

# Поднять IP на usb0 в конце скрипта
if ip link show usb0 >/dev/null 2>&1; then
    ip addr add 192.168.7.2/24 dev usb0 2>/dev/null || true
    ip link set usb0 up
fi
```

После правки `make usb-gadget-install && make _image_pack`.

На стороне ПК:

- Linux/macOS это драйвер `cdc_ncm` подхватится автоматически, появится сетевой интерфейс.
- Windows 10 1709+ это нужен `usbncm.inf`. Установка через `DISM.exe /Online /Add-Capability /CapabilityName:USB:USBNCM~~~~0.0.1.0` или через Settings → Apps → Optional features. Если capability недоступен, поставить кастомный INF или сменить функцию на ECM (Class_02 SubClass_06).

IP-адресная схема при USB Ethernet:

```
Плата usb0  192.168.7.2/24
ПК    enx*  192.168.7.1/24  (настраивается вручную)
```

Команды на ПК (Linux):
```
sudo ip addr add 192.168.7.1/24 dev enxXXXXXXX
sudo ip link set enxXXXXXXX up
ssh root@192.168.7.2
```

Команды на ПК (Windows PowerShell):
```powershell
New-NetIPAddress -InterfaceAlias "Ethernet X" -IPAddress 192.168.7.1 -PrefixLength 24
ssh root@192.168.7.2
```

### Изменение конфигурации gadget

Для добавления функций (Mass Storage, HID, etc.) редактируем `scripts/setup-usb-gadget.sh`:

```sh
# Mass Storage с backing-файлом
dd if=/dev/zero of=/var/lib/usb-storage.img bs=1M count=256
mkdir -p $GADGET/functions/mass_storage.usb0/lun.0
echo /var/lib/usb-storage.img > $GADGET/functions/mass_storage.usb0/lun.0/file
ln -s $GADGET/functions/mass_storage.usb0 $GADGET/configs/c.1/
```

После правки:
```
make usb-gadget-install
make _image_pack
```

Live-изменение на работающей плате без пересборки:
```
systemctl stop usb-gadget.service
echo "" > /sys/kernel/config/usb_gadget/g1/UDC
# отредактировать configfs-дерево
echo "$(ls /sys/class/udc/)" > /sys/kernel/config/usb_gadget/g1/UDC
```

### Диагностика

| Симптом | Что проверить |
|---|---|
| `usb-gadget.service` failed | `journalctl -u usb-gadget.service -b 0` |
| Нет `/sys/class/udc/4340000.usb` | `lsmod \| grep dwc2`, `dmesg \| grep dwc2` |
| `/dev/ttyGS0` не появляется | `cat /sys/kernel/config/usb_gadget/g1/UDC` (должен быть `4340000.usb`) |
| ПК не видит USB-устройство | Кабель Type-C это data-кабель (тестировался для передачи файлов)? VBUS-detection в `dmesg` платы? |
| Windows: устройство в Error Code 28 | Драйвера нет в системе. Для ACM этого быть не должно, проверьте composite parent. |
| Windows: устройство без MI_XX суффикса | Multi-config gadget. Скрипт должен быть single-config. |
| Login prompt на ACM пустой | `systemctl status serial-getty@ttyGS0.service`, проверить `agetty` не висит |
| COM-port в Windows есть, но не печатает | Windows кэшировал старый driver-binding. `pnputil /remove-device <InstanceId>` и переподключить. |

### Откат к режиму без gadget

```
systemctl disable --now usb-gadget.service
echo "" > /sys/kernel/config/usb_gadget/g1/UDC
rm -rf /sys/kernel/config/usb_gadget/g1
```

После reboot контроллер DWC2 останется в `otg` режиме без gadget-функций. Если подключить USB-периферию через OTG-переходник, контроллер заработает как host.

## ACM на ранних стадиях boot

Вопрос: с какого момента boot-chain доступен USB ACM как console.

Короткий ответ это ACM работает начиная с U-Boot, но без серьёзных доработок реально полезен только из Linux.

### MaskROM

В SG2002 встроен USB-recovery режим. По boot-strap pin или удержанию кнопки MaskROM представляется ПК как USB-устройство, принимает прошивку через проприетарный протокол CviUsbBurnTool (Sophgo). Не ACM, не shell. Часть hardware ROM, переписать невозможно. Используется только для firmware recovery.

### FSBL/BL2 (TF-A)

Минимальный код, инициализирует DDR + cvirtos + переходит в OpenSBI. USB-стека нет. Добавить теоретически можно, переписав FSBL целиком, практически нерезонно.

### OpenSBI

Тонкий SBI-runtime в M-mode. По дизайну работает с UART для early console, USB-драйверов нет ни в upstream, ни в Sophgo-fork. Добавление DWC2 + gadget-стека это эквивалент написания нового субпроекта. Не делается.

### U-Boot

USB gadget реально работает. mainline U-Boot имеет:

```
CONFIG_USB_GADGET=y
CONFIG_USB_GADGET_DWC2_OTG=y
CONFIG_USB_FUNCTION_ACM=y           # ACM console
CONFIG_USB_FUNCTION_DFU=y           # firmware upgrade
CONFIG_USB_FUNCTION_FASTBOOT=y      # Android fastboot
CONFIG_USB_FUNCTION_MASS_STORAGE=y  # UMS, плата это USB-флешка
```

После сборки в U-Boot доступны команды:

```
=> dfu 0 mmc 0          # firmware upgrade gadget
=> fastboot usb 0       # Android fastboot
=> ums 0 mmc 0          # SD-card как USB-флешка
=> acm                  # ACM console (опционально)
```

Три способа использовать USB в U-Boot:

1. ACM как stdout/stdin это `stdin=serial,usbacm`, `stdout=serial,usbacm`. U-Boot ждёт USB-enumeration ~3-5 секунд. Если ПК не подключён, висим. Multi-console смягчает (UART работает параллельно).
2. Команда `acm` запускает gadget по требованию.
3. `dfu` / `fastboot` / `ums` для recovery, не для shell.

Тонкости интеграции для cv180x:

- Включить опции выше в `sipeed_licheerv_nano_defconfig`.
- Добавить узел `usb@4340000` в U-Boot DT (он отдельный от kernel DT, копировать аналогично).
- Возможно backport DWC2 из vendor U-Boot Sophgo, mainline-код на cv180x PHY (System control 0x03000048) не тестировался.
- Пересборка U-Boot + FIP.

Объём работы это ~1-2 дня, риск что mainline DWC2 не заведётся на специфике PHY cv180x.

### Linux kernel handoff (initramfs)

Самый ранний реалистичный момент для ACM в Linux это initramfs. Стадии:

1. В initramfs встраивается `libcomposite.ko`, `usb_f_acm.ko`, скрипт настройки configfs.
2. Init-stage скрипт монтирует configfs, поднимает gadget до `switch_root`.
3. ACM доступен через ~1 секунду после kernel handoff.

Нужно собрать initramfs (Debian `update-initramfs` или вручную через `mkinitramfs`), добавить hook в `/etc/initramfs-tools/scripts/init-bottom/`.

### Linux systemd

Стандартный сценарий, см. раздел «Systemd-сервис автозапуска» выше. ACM поднимается через `sysinit.target`, доступен через ~3 секунды после kernel start (~5-8 секунд от power-on).

### Сводка по стадиям

| Стадия | ACM возможен | Что доступно реально | Реалистично |
|---|---|---|---|
| MaskROM | Нет | CviUsbBurnTool (vendor protocol) | Только recovery |
| FSBL/BL2 | Нет (нужен USB-стек с нуля) | Ничего | Нет |
| OpenSBI | Нет (нужен USB-стек с нуля) | Ничего | Нет |
| U-Boot | Да | ACM, DFU, fastboot, UMS | Через 1-2 дня доработки defconfig + DT |
| Linux kernel handoff | Через initramfs | ACM, RNDIS, etc | Да, ~1 сек |
| Linux systemd | Да | Полный configfs gadget | Самый простой, ~3 сек |

### Практическая рекомендация

Реальная польза от раннего ACM на этой плате невелика. Для recovery достаточно MaskROM USB-burn режима. Для повседневной работы достаточно ACM из systemd (~3 секунды после kernel start). Только если нужен U-Boot prompt для отладки (выбор пункта меню extlinux, ввод команд) имеет смысл USB-ACM в U-Boot, но проще оставить UART, который работает с первой секунды.

Если хочется максимально рано иметь USB-console, оптимальный путь это initramfs-юнит, не U-Boot.

## Известные ограничения

- На SG2002 нет полноценного USB-C PD контроллера, переключение роли только через VBUS sense.
- Mainline DWC2 не всегда корректно срабатывает на VBUS-detection без отдельного `usb-role-switch` биндинга. Если OTG-режим не переключается, проще пиннить через cmdline.
- При работе в peripheral-режиме плата может ловить просадку питания, если ПК ограничивает ток порта.

## Связанные документы

- `docs/sg2002_pin_map.md` это раздел USB и Type-C
- из vendor-архива Sipeed извлечены base + IRQ
- `patches/linux/0007-licheerv-nano-usb-dwc2.patch` это сам патч с DT-узлом
