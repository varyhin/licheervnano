# I2C на LicheeRV Nano

Краткая инструкция по работе с шинами I2C1 и I2C3 на 2×14-pin header
LicheeRV Nano под mainline Linux 6.18.29.

Статус: шины включены в board-DTS с pinmux (патч 0021), доступны
только на вариантах B и E.

## Только варианты B и E

I2C1 и I2C3 живут на падах `SD1_D3/SD1_D0/SD1_CMD/SD1_CLK` (SoC 51-56).
На вариантах W и WE эти же пады это шина SDIO радиомодуля AIC8800
(vendor `cvi_board_init.c` держит их в func0, «wifi sdio pinmux»).
Remux в I2C на живом радио физически отключает Wi-Fi чип от SoC: CMD52
перестаёт проходить, драйвер падает в `cmd queue crashed` (регрессия,
найдена и устранена на железе W 2026-06-11). Поэтому pinctrl-группы
I2C1/I2C3 описаны только в board-DTS вариантов B и E, а в DTS W/WE
узлы `&i2c1`/`&i2c3` отключены. На W/WE шин I2C1 и I2C3 нет, это
аппаратная цена Wi-Fi.

## Что включено в образ

- DTS активирует `&i2c1` и `&i2c3` со status okay
  (`patches/linux/0004-licheerv-nano-i2c.patch`)
- DTS aliases дают предсказуемые `/dev/i2c-1` и `/dev/i2c-3` вместо
  динамической нумерации (`/dev/i2c-0/1` по порядку probe)
- `/etc/modules-load.d/i2c-dev.conf` автозагружает модуль `i2c-dev` на
  boot чтобы появились chardev-узлы
- Pinmux падов задаётся в board-DTS B/E через pinctrl
  (`patches/linux/0021-licheerv-nano-pinmux-i2c-uart-dts.patch`):
  `PINMUX(PIN_SD1_D3/D0, 2)` для I2C1 и `PINMUX(PIN_SD1_CMD/CLK, 2)`
  для I2C3, применяется драйвером при probe. Прежний
  `setup-i2c-pinmux.service` (runtime devmem) удалён 2026-06-11:
  обоснование «pinctrl-sg2002 не имеет именованных пинов» устарело,
  имена `PIN_SD1_*` есть в `dt-bindings/pinctrl/pinctrl-sg2002.h`
- Установлены пакеты `i2c-tools` (i2cdetect, i2cget, i2cset, i2cdump),
  `busybox` (devmem applet)

## Регистры pinmux

Из Sipeed wiki (https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/5_peripheral.html,
section I2C):

| Шина | SCL register | SDA register | Значение |
|---|---|---|---|
| I2C1 | `0x030010D0` | `0x030010DC` | `0x2` |
| I2C3 | `0x030010E4` | `0x030010E0` | `0x2` |

Значения справочные (тот же эффект, что у pinctrl-групп из патча
0021), руками их писать не нужно.

## Проверка что bus работает (без подключенных устройств)

```
# 1. Bus driver probed
ls /sys/bus/i2c/devices/
# хочется увидеть i2c-1 и i2c-3

# 2. Driver имя
cat /sys/bus/i2c/devices/i2c-1/name
# Synopsys DesignWare I2C adapter

# 3. Функционал bus (без сканирования)
i2cdetect -F 1
# I2C, SMBus quick command, SMBus byte read, и т.д. = yes

# 4. Сканирование (пустая сетка без устройств — это нормально)
i2cdetect -y 1
i2cdetect -y 3
# 16x16 grid с '--' в каждой клетке означает bus работает, устройств нет

# 5. Попытка чтения с произвольного адреса (даст NACK error)
i2cget -y 1 0x50 0
# 'Error: Read failed' = bus работает, на 0x50 никого нет

# 6. Pinmux установлен (pinctrl применяется при probe i2c-драйвера)
busybox devmem 0x030010D0
busybox devmem 0x030010DC
busybox devmem 0x030010E4
busybox devmem 0x030010E0
# все четыре должны вернуть 0x00000002
```

## Подключение устройств

Pinout 2×14-pin header (см. Sipeed wiki, актуальный порядок проверьте
на плате):

- I2C1 SCL и SDA: смотрите schematic для конкретной ревизии
- I2C3 SCL и SDA: аналогично

Подключение типичного устройства (EEPROM 24C32, RTC DS1307, OLED SSD1306):

1. VCC → 3.3V на header
2. GND → GND
3. SCL → SCL pin шины
4. SDA → SDA pin шины

После подключения:

```
i2cdetect -y 1
# или -y 3 в зависимости от шины
```

Если устройство отвечает, его адрес появится в таблице (не `--`, а
hex-число). Например EEPROM на 0x50, OLED на 0x3c.

## Примеры использования

### Чтение EEPROM 24C32 (адрес 0x50, шина I2C1)

```
# Прочитать байт по offset 0x00
i2cget -y 1 0x50 0x00

# Записать байт 0xAA по offset 0x00
i2cset -y 1 0x50 0x00 0xAA

# Дамп первых 256 байт
i2cdump -y 1 0x50
```

### Чтение OLED SSD1306 status (адрес 0x3c)

```
i2cget -y 1 0x3c 0x00
# обычно возвращает status byte controller'а
```

### Чтение всех регистров RTC DS1307 (адрес 0x68)

```
i2cdump -y 1 0x68 b 0x00 0x3f
```

## Программный доступ

`/dev/i2c-1` и `/dev/i2c-3` это стандартные Linux chardev. Доступ через:

- C: `<linux/i2c-dev.h>` + `ioctl(I2C_SLAVE, ...)` + `read/write`
- Python: `smbus2` или `python3-smbus` пакет (не установлен по умолчанию)
- Shell: `i2c-tools` (стандарт)

Пример Python (нужно установить `python3-smbus`):

```python
import smbus2
bus = smbus2.SMBus(1)  # /dev/i2c-1
value = bus.read_byte_data(0x50, 0x00)
print(hex(value))
```

## Известные ограничения

- Pinmux принадлежит pinctrl-фреймворку (патч 0021). Ручной remux
  этих регистров через devmem обходит фреймворк и на W/WE отрезает
  SDIO Wi-Fi, не делать
- Максимальная скорость по умолчанию 100 kHz (standard mode). Для
  400 kHz fast mode добавить в DTS `clock-frequency = <400000>;` в
  узел `&i2c1` / `&i2c3`

## Troubleshooting

- `i2cdetect -y 1` ошибка `Could not open` → проверить `lsmod | grep i2c_dev`,
  загрузить через `modprobe i2c-dev`
- `/sys/bus/i2c/devices/` пуст → DTS не активировал узлы, проверить что
  загружен правильный dtb (`fdt addr` в U-Boot или `cat /proc/device-tree/aliases/i2c1`)
- Все устройства не отвечают → pinmux не установлен, проверить вывод
  `busybox devmem 0x030010D0` (должен быть 0x2); на W/WE шины
  отключены by design
- Один адрес отвечает на всех адресах одновременно → SCL/SDA коротят
  на VCC или GND, проверить physical connections и pull-up резисторы

## Связанные документы

- `docs/uart_setup.md` это похожая структура pinmux (тот же патч 0021) на 2x14 header
- `docs/gpio_setup.md` это разделение между I2C и GPIO на одних пинах
- `docs/sg2002_pin_map.md` это распиновка SoC + 2x14 header
- `patches/linux/0004-licheerv-nano-i2c.patch` это активация I2C1+I2C3
