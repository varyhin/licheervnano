# UART на LicheeRV Nano

Краткая инструкция по работе с UART1 и UART2 на 2×14-pin header
LicheeRV Nano под mainline Linux 6.18.29.

Статус: порты включены в board-DTS патчем 0005, pinmux добавлен патчем 0021.

## Что включено в образ

- DTS активирует `&uart1` и `&uart2` со status okay
  (`patches/linux/0005-licheerv-nano-uart.patch`)
- DTS aliases `serial1 = &uart1`, `serial2 = &uart2` уже описаны в base
  DTS, дают предсказуемые `/dev/ttyS1` и `/dev/ttyS2`
- Pinmux падов задаётся в board-DTS через pinctrl
  (`patches/linux/0021-licheerv-nano-pinmux-i2c-uart-dts.patch`):
  UART1 на `PINMUX(PIN_JTAG_CPU_TMS/TCK, 6)`, UART2 на
  `PINMUX(PIN_IIC0_SCL/SDA, 2)`, применяется драйвером при probe.
  Прежний `setup-uart-pinmux.service` (runtime devmem) удалён
  2026-06-11: обоснование «pinctrl-sg2002 не имеет именованных пинов»
  устарело, имена `PIN_*` есть в `dt-bindings/pinctrl/pinctrl-sg2002.h`
- UART0 остаётся kernel console на пинах `A16 (TX) / A17 (RX)` SoC
  (это та же UART через которую пишется boot log), его конфигурация
  не меняется
- UART3 пропущен (конфликт pinmux с I2C1 и SDIO Wi-Fi)
- UART4 не выведен Sipeed на 2x14 header
- `/dev/ttyGS0` это USB ACM gadget на Type-C порту, активируется через
  `usb-gadget.service`. Альтернативный console без UART-конвертера,
  см. `docs/usb_setup.md`

## Регистры pinmux

Из Sipeed wiki (https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/5_peripheral.html,
section "UART1 UART2 UART3"):

| Шина | TX register | RX register | Значение |
|---|---|---|---|
| UART2 | `0x03001070` | `0x03001074` | `0x2` |
| UART1 | `0x03001064` | `0x03001068` | `0x6` |

UART2 садится на GPIOA28 (TX) и GPIOA29 (RX), это default position
для UART1. UART1 перенесён на GPIOA19 (TX) и GPIOA18 (RX), чтобы
обе шины не конфликтовали. Значения в таблице справочные (тот же
эффект, что у pinctrl-групп из патча 0021), руками их писать не нужно.

## Проверка что устройства появились

```
# 1. devnode присутствует
ls /dev/ttyS* /dev/ttyGS*
# хочется увидеть /dev/ttyS0 (console), /dev/ttyS1 (UART1), /dev/ttyS2 (UART2),
# и /dev/ttyGS0 (USB ACM gadget)

# 2. Driver matched
ls /sys/class/tty/ttyS1/device/
# должен быть симлинк driver -> dw-apb-uart

# 3. Pinmux установлен (pinctrl применяется при probe uart-драйвера)
busybox devmem 0x03001070
busybox devmem 0x03001074
busybox devmem 0x03001064
busybox devmem 0x03001068
# первые два должны вернуть 0x00000002 (UART2)
# вторые два должны вернуть 0x00000006 (UART1)

# 4. pinctrl-группы видны ядру
grep -A2 uart /sys/kernel/debug/pinctrl/3001000.pinctrl/pinmux-pins 2>/dev/null | head
```

## Простая проверка через loopback

Замкнуть GPIOA28 и GPIOA29 коротким проводом (TX↔RX UART2 на header).
Можно использовать аналогичный приём для UART1 (GPIOA19↔GPIOA18).

```
stty -F /dev/ttyS2 115200 raw -echo
# в одной сессии:
cat /dev/ttyS2 &
# в другой:
echo hello > /dev/ttyS2
# на cat'е должно появиться "hello"
```

Без loopback можно отправить байты, но прочитать назад нечего:

```
echo -n UUU > /dev/ttyS2  # отправит 0x55 0x55 0x55
```

## Подключение внешнего USB-UART адаптера

Типичный сценарий, подключиться к ttyS1 на плате с другого хоста.

1. На плате: `agetty -L 115200 ttyS1` (или прописать systemd unit
   `serial-getty@ttyS1.service`, см. ниже)
2. Подключение GPIOA19 (UART1 TX) к RX адаптера, GPIOA18 (UART1 RX)
   к TX адаптера, GND к GND
3. На хосте: `picocom -b 115200 /dev/ttyUSB0`

После этого появится login prompt по UART1.

### Автозапуск getty на ttyS1

```
systemctl enable --now serial-getty@ttyS1.service
```

После этого systemd сам поднимет login prompt на /dev/ttyS1 при boot.

## Альтернатива USB-UART: USB ACM gadget

С момента добавления USB Gadget bring-up (см. `docs/usb_setup.md`), для
получения console-доступа к плате USB-UART конвертер больше не обязателен:

- Type-C от платы к ПК это плата питается и сразу отдаёт виртуальный
  COM-port на хосте.
- `/dev/ttyGS0` на плате это login prompt от `serial-getty@ttyGS0`,
  запускается автоматически из `setup-usb-gadget.sh`.
- На ПК Linux это `/dev/ttyACM0`, на Windows это `COMx`, на macOS это
  `/dev/cu.usbmodem*`. Подключение через `screen`/`picocom`/PuTTY на
  скорости 115200.

UART-конвертер всё ещё полезен в трёх сценариях:
- Подключить к header (UART1/UART2) внешнее периферийное устройство,
  где плата это master, а не клиент.
- Видеть boot-log с FSBL/OpenSBI/U-Boot стадий (USB ACM поднимается
  только после старта Linux + systemd, ранний boot не видно).
- Плата как USB host (через OTG-переходник), когда Type-C занят
  USB-флешкой и gadget не активен.

## Программный доступ

`/dev/ttyS1` и `/dev/ttyS2` это стандартные Linux tty char-devices.
Доступ через:

- C: `<termios.h>` + `open() / tcsetattr() / read() / write()`
- Python: `pyserial` (не установлен по умолчанию)
- Shell: `stty` + `echo` / `cat` / `hexdump`

Пример Python (нужно `pip install pyserial`):

```python
import serial
ser = serial.Serial("/dev/ttyS1", 115200, timeout=1)
ser.write(b"hello\r\n")
print(ser.read(64))
```

## Поддерживаемые скорости

DesignWare UART в SG2002 умеет стандартные baud rates от 1200 до
4 Mbaud. Тактовую частоту даёт clock-controller через `<&clk CLK_UART0>`
(клок `clk_uart0` определён в `drivers/clk/sophgo/clk-cv1800.c`, не в DTS).
Реальная частота 25 MHz, это подтверждает драйвер 8250 в dmesg
(`base_baud = 1562500`, то есть uartclk / 16). Делитель baud разрешает любые
скорости кратные `25e6 / (16 * N)` без существенной ошибки до 1.5 Mbaud.

Установить нестандартную скорость:

```
stty -F /dev/ttyS1 921600 raw
```

## Hardware flow control

CTS/RTS не подключены к pinmux (нужны были бы дополнительные
регистры). Если потребуется hw flow control, расширить pinctrl-группы
в патче 0021:

```
# UART1 RTS/CTS (gpio18/19 уже заняты под TX/RX в нашей схеме)
# Эта конфигурация требует переоформления pinmux, см. wiki Sipeed
```

По дефолту в этой сборке CTS/RTS отключены, работает только TX/RX.

## Известные ограничения

- Pinmux принадлежит pinctrl-фреймворку (патч 0021). Ручной remux
  этих регистров через devmem обходит фреймворк, не делать
- UART3 и UART4 не выведены (см. секцию "Что включено в образ" выше)

## Troubleshooting

- `/dev/ttyS1` отсутствует → DTS не активировал узел uart1, проверить
  что загружен правильный dtb (`cat /proc/device-tree/aliases/serial1`)
  и что в DTS прописано `&uart1 { status = "okay"; };`
- Мусор в чтении/нет ответа от устройства → pinmux не установлен или
  не сходится baud rate. Проверить `busybox devmem 0x03001070` (для
  UART2 на GPIOA28 должно быть `0x2`)
- На echo через ttyS1 видно мусор обратно → возможно сам UART
  слышит свою echo (программный, не аппаратный). В serial устройстве
  отключить `echo` через `stty -F /dev/ttyS1 -echo`
- `agetty` не запускается → проверить `systemctl status serial-getty@ttyS1`,
  в логах может быть "device or resource busy" если другой процесс
  держит порт

## Связанные документы

- `docs/usb_setup.md` это альтернатива UART через ACM gadget (Type-C → COM-port на ПК)
- `docs/i2c_setup.md` это похожая структура pinmux через devmem на 2x14 header
- `docs/sg2002_pin_map.md` это распиновка SoC + 2x14 header
- `patches/linux/0005-licheerv-nano-uart.patch` это активация UART1+UART2
