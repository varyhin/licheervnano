#!/bin/sh
# USB Gadget: ACM (console) на DWC2 контроллере SG2002.
#
# Минимальная single-function конфигурация для console-over-USB:
#   - Type-C от платы к ПК это виртуальный COM-port на хосте
#   - /dev/ttyGS0 на плате это login getty
#   - Не зависит от наличия NCM/RNDIS драйверов на стороне ПК
#
# Если нужен полный стек single-cable (console + SSH + scp), вернуть
# NCM или RNDIS функции через ln -s functions/ncm.usb0 configs/c.1/
# и установить соответствующий driver на ПК.
#
# Связь с платой по сети это через регулярный Ethernet RJ45
# (вариант E/WE), Wi-Fi (вариант W/WE), или Type-C если поднят
# usb-network gadget.

set -e

GADGET=/sys/kernel/config/usb_gadget/g1

# 1. configfs смонтирован (systemd обычно делает это автоматически)
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# 2. libcomposite загружен (модуль)
modprobe libcomposite

# Idempotent: если gadget уже создан, не пересоздавать
[ -d "$GADGET" ] && exit 0

# 3. Базовая конфигурация устройства
mkdir -p "$GADGET"
cd "$GADGET"

echo 0x1d6b > idVendor        # Linux Foundation
echo 0x0104 > idProduct       # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "Sipeed"        > strings/0x409/manufacturer
echo "LicheeRV Nano" > strings/0x409/product

# Уникальный serial из machine-id или fallback
SERIAL=$(cat /etc/machine-id 2>/dev/null | head -c 16)
echo "${SERIAL:-licheerv0001}" > strings/0x409/serialnumber

# 4. Функция: только ACM
mkdir -p functions/acm.usb0

# 5. Единственная конфигурация c.1 с ACM
mkdir -p configs/c.1/strings/0x409
echo "ACM" > configs/c.1/strings/0x409/configuration
echo 250   > configs/c.1/MaxPower
ln -s functions/acm.usb0 configs/c.1/

# 6. Ждём появления UDC (DWC2 пробится через udev, может быть с задержкой)
UDC=""
for i in 1 2 3 4 5; do
	UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n1)
	[ -n "$UDC" ] && break
	sleep 1
done
[ -z "$UDC" ] && { echo "no UDC available, dwc2 module loaded?" >&2; exit 1; }

# 7. Привязка к UDC это активация gadget
echo "$UDC" > UDC

# 8. Ждём появления виртуального ttyGS0 (kernel создаёт после enumeration)
for i in 1 2 3 4 5; do
	[ -e /dev/ttyGS0 ] && break
	sleep 1
done

# 9. Запустить getty на ACM (если systemd доступен)
if command -v systemctl >/dev/null 2>&1 && [ -e /dev/ttyGS0 ]; then
	systemctl restart serial-getty@ttyGS0.service 2>/dev/null || true
fi
