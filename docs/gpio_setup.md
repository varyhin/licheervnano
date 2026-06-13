# GPIO на LicheeRV Nano

Краткая инструкция по работе с GPIO 2x14 header LicheeRV Nano под
mainline Linux 6.18.29.

Статус: GPIO chips и USER LED проверены на железе 2026-06-03.

## Что включено в образ

- Mainline `pinctrl-sg2002` + `snps,dw-apb-gpio` драйверы (built-in)
  автоматически регистрируют 4 gpiochip при boot
- Пакет `gpiod` (libgpiod tools) установлен в rootfs через EXTRA_PKGS,
  доступны `gpioinfo`, `gpioget`, `gpioset`, `gpiomon`, `gpiofind`
- USER LED `licheerv-nano:blue:user` и USER button `KEY_DISPLAYTOGGLE`
  описаны в board-DTS, обрабатываются через `gpio-leds` и `gpio-keys`
  сами по себе

## Mapping gpiochip → SoC porta/b/c/d

| gpiochip | SoC порт | Адрес | Назначение |
|---|---|---|---|
| gpiochip0 | porta (XGPIOA) | 0x03020000 | EMMC/SD0 power domain, console pins, header левая сторона |
| gpiochip1 | portb (XGPIOB) | 0x03021000 | ETH PHY power domain (только E/WE) |
| gpiochip2 | portc (XGPIOC) | 0x03022000 | MIPI power domain (camera/display, header не выводит) |
| gpiochip3 | portd (PWR_GPIO) | 0x03023000 | RTC/SD1 power domain, header правая сторона |

Каждый порт 32 линии (`ngpios = <32>`), всего теоретически 128 GPIO.
Реально физически выведено намного меньше (см. `docs/sg2002_pin_map.md`).

## Header pins → gpiochip lines

Краткая выжимка для 2x14 header. Полная таблица в `docs/sg2002_pin_map.md`.

| Header label | gpiochip:line | Текущая роль | Замечание |
|---|---|---|---|
| GPIOA 14 | gpiochip0 line 14 | USER LED (синий), off по умолчанию | через `/sys/class/leds/licheerv-nano:blue:user/` |
| GPIOA 15 | gpiochip0 line 15 | SPK_EN (amp enable, занят драйвером sound_dac, -EBUSY для userspace) | spk-en-gpios, патчи 0012/0013 |
| GPIOA 16 | gpiochip0 line 16 | UART0 TX (console) | менять опасно |
| GPIOA 17 | gpiochip0 line 17 | UART0 RX (console) | менять опасно |
| GPIOA 18 | gpiochip0 line 18 | UART1 RX (pinmux 0x6) | переключить можно, потеряете UART1 |
| GPIOA 19 | gpiochip0 line 19 | UART1 TX (pinmux 0x6) | переключить можно, потеряете UART1 |
| GPIOA 22 | gpiochip0 line 22 | свободен (EMMC_CLK pin) | |
| GPIOA 23 | gpiochip0 line 23 | свободен (EMMC_CMD pin) | |
| GPIOA 24 | gpiochip0 line 24 | свободен (EMMC_DAT1 pin) | |
| GPIOA 25 | gpiochip0 line 25 | свободен (EMMC_DAT0 pin) | |
| GPIOA 26 | gpiochip0 line 26 | свободен на B/E (EMMC_DAT2 pin) | на W/WE занят Wi-Fi pwrseq reset (porta 26, патч 0001) |
| GPIOA 28 | gpiochip0 line 28 | UART2 TX (pinmux 0x2) | переключить можно, потеряете UART2 |
| GPIOA 29 | gpiochip0 line 29 | UART2 RX (pinmux 0x2) | переключить можно, потеряете UART2 |
| GPIOA 30 | gpiochip0 line 30 | USER button KEY_DISPLAYTOGGLE | через input event |
| GPIOP 18 | нет линии gpiochip3 | не выведен (вакантный SoC pin 50, QFN-38) | заглушка, см. sg2002_pin_map.md |
| GPIOP 19 | gpiochip3 line 18 | I2C1 SCL (pinmux 0x2) | SD1_D3, PWR_GPIO[18]; на W/WE это SDIO1 D3 |
| GPIOP 20 | gpiochip3 line 23 | I2C3 SDA (pinmux 0x2) | SD1_CLK, PWR_GPIO[23]; на W/WE это SDIO1 CLK |
| GPIOP 21 | gpiochip3 line 22 | I2C3 SCL (pinmux 0x2) | SD1_CMD, PWR_GPIO[22]; на W/WE это SDIO1 CMD |
| GPIOP 22 | gpiochip3 line 21 | I2C1 SDA (pinmux 0x2) | SD1_D0, PWR_GPIO[21]; на W/WE это SDIO1 D0 |

Чтобы переключить пин в чистый GPIO режим (выйти из I2C/UART функции),
надо записать pinmux register на функцию `0x3` (XGPIO) через
`busybox devmem`. См. `docs/sg2002_pin_map.md` колонку Func3.

## Базовая проверка

В Debian 13 trixie установлен `libgpiod` 2.x. Синтаксис команд изменился
по сравнению с 1.x: positional аргумент это имя линии, а chip задаётся
через `-c`.

```
# Список всех gpiochips и метаданных
gpiodetect
# gpiochip0 [3020000.gpio] (32 lines)
# gpiochip1 [3021000.gpio] (32 lines)
# gpiochip2 [3022000.gpio] (32 lines)
# gpiochip3 [3023000.gpio] (32 lines)

# Подробно про gpiochip0 (XGPIOA)
gpioinfo -c gpiochip0
# покажет 32 линии с их текущим статусом (input/output, kernel-claimed)

# Все линии всех chip
gpioinfo
```

Kernel занимает линии 14 (USER LED через gpio-leds) и 30 (USER button
через gpio-keys), они показываются как `consumer="gpio-keys"` или
`consumer="leds-gpio"` в `gpioinfo`.

## Чтение и установка линии

Например подать high на свободную EMMC_CLK pin (gpiochip0 line 22, свободна на всех вариантах):

```
# Установить high
gpioset -c gpiochip0 22=1

# Установить low
gpioset -c gpiochip0 22=0

# Прочитать
gpioget -c gpiochip0 22
```

Несколько линий одновременно:

```
gpioset -c gpiochip0 22=1 23=0 24=1
```

`gpioset` в v2 по дефолту освобождает линию после exit (значение
сбрасывается). Чтобы удержать значение пока процесс жив, используйте
`--toggle` или `--hold-period` + interactive mode `-i`. Простой
вариант фоновым процессом:

```
gpioset --hold-period 60s -c gpiochip0 22=1
# держит high 60 секунд
```

Или просто запустить `gpioset` в активной shell сессии и не выходить
(Ctrl-C сбросит).

## Мониторинг событий

`gpiomon` блокирует и ждёт edge (rising, falling, both).

```
# Все фронты на GPIOA 26 (по дефолту обоих типов)
gpiomon -c gpiochip0 26

# Только rising
gpiomon -e rising -c gpiochip0 26

# Только falling
gpiomon -e falling -c gpiochip0 26

# Один event и exit
gpiomon -n 1 -c gpiochip0 26
```

## USER LED (синий у кнопки USER) через sysfs

Синий LED у кнопки USER это user-LED `D1` на `GPIOA14`, единственный управляемый LED на плате (подтверждено на железе 2026-06-03). Красный у кнопки RESET это `LED2`, аппаратный индикатор питания 3.3V (`VDD3V3_SYS → LED2 → R30 5.1K → GND`), к GPIO НЕ подключён, софтом не управляется, отключить только выпайкой `R30`/`LED2`.

Полярность синего это `GPIO_ACTIVE_HIGH` (пин HIGH = горит), и по умолчанию LED ВЫКЛЮЧЕН при загрузке (`default-state = "off"`, без триггера, управляется через sysfs). Пад `GPIOA14` это `SD0_PWR_EN`, его переводит в GPIO DTS-pinctrl (`PINMUX(PIN_SD0_PWR_EN, 3)`), иначе boot оставляет fmux=0x0 и синий горит всегда. Всё в board-DTS (патч `0018`; active-high это отсутствие прежнего `0006`). Лейбл `licheerv-nano:blue:user`. Детали в `docs/led_setup.md`.

```
LED=/sys/class/leds/licheerv-nano:blue:user
ls /sys/class/leds/        # licheerv-nano:blue:user
cat $LED/trigger           # доступные режимы, в [скобках] текущий
```

### Режим: ручной on/off (`none`)

```
echo none > $LED/trigger   # отвязать триггер, отдать управление brightness
echo 1 > $LED/brightness   # включить (active-high; max_brightness=1)
echo 0 > $LED/brightness   # выключить
```

### Режим: индикатор SD/eMMC (`mmc0` / `mmc1`)

```
echo mmc0 > $LED/trigger   # вспышка при доступе к microSD, параметров нет
echo mmc1 > $LED/trigger   # то же для второго mmc-контроллера
dd if=/dev/mmcblk0 of=/dev/null bs=1M count=50   # спровоцировать вспышки для проверки
```

### Режим: пульс (`heartbeat`)

```
echo heartbeat > $LED/trigger   # пульс ~1 Гц, частота растёт с загрузкой CPU
cat $LED/invert                 # триггер добавляет параметр invert (0/1)
echo 1 > $LED/invert            # инвертировать фазу пульса
```

### Режим: всегда включён (`default-on`)

```
echo default-on > $LED/trigger  # горит постоянно, параметров нет
```

### Режим: активность диска (`disk-activity` / `disk-read` / `disk-write`)

```
echo disk-activity > $LED/trigger   # вспышка на любой block-I/O (включая SD)
echo disk-read > $LED/trigger        # только чтение
echo disk-write > $LED/trigger       # только запись
```

### Режим: состояние клавиш (`kbd-*`)

```
echo kbd-capslock > $LED/trigger    # LED = состояние CapsLock (нужна USB-клавиатура)
# аналогично kbd-numlock, kbd-scrolllock, kbd-shiftlock и пр.
```

### Сброс к дефолту и персист между перезагрузками

```
echo mmc0 > $LED/trigger            # включить индикацию SD-активности
```

По умолчанию LED выключен при ребуте (`default-state = "off"`, без триггера). Чтобы при загрузке был активен режим: добавить `linux,default-trigger` в board-DTS (ребилд dtb), либо выставлять триггер на старте (systemd-unit, udev-rule или `rc.local`). Произвольную частоту мигания штатно даёт триггер `timer` (`delay_on`/`delay_off`), но `CONFIG_LEDS_TRIGGER_TIMER` у нас выключен, без пересборки ядра используйте `heartbeat` или мигайте скриптом в режиме `none`.

### Дополнительные vendor-режимы

`activity` (дефолт vendor у `led-user`), `cpu`, `netdev` (tx/rx/link сети), `panic` и `uleds` (`LEDS_USER`, LED из userspace через `/dev/uleds`) включены в нашем kernel-конфиге (блок scripts/config в Makefile, target kernel) и доступны в образе. `camera`-триггера в mainline нет. Триггер у user-LED по умолчанию не задан (`default-state = "off"`). Любая правка `.config` требует пересборки ядра И ВСЕХ модулей (смена конфига меняет ABI структур).

Пример настройки `netdev`:
```
echo netdev > $LED/trigger
echo eth0 > $LED/device_name        # привязать к интерфейсу
echo 1 > $LED/link                  # гореть при наличии линка
echo 1 > $LED/tx ; echo 1 > $LED/rx # мигать на трафике
```

## Кнопки USER и RESET

На плате две кнопки. Только одна видна софту.

- Кнопка `USER` (схемный `SW1`, она же BOOT_KEY) это `GPIOA[30]`, заведена как `gpio-keys`. Полярность `GPIO_ACTIVE_LOW` (подтяжка 10K к VDD3V3, нажатие тянет в LOW). Keycode это `KEY_DISPLAYTOGGLE` = `0x1af` = 431. В системе это `/dev/input/event0`.
- Кнопка `RESET` (схемный `SW2`, она же SYS_RSTN) это аппаратный сброс в домене VDD1V8 (R64 10K, C63 100nF debounce). К GPIO не подключена, в DTS отсутствует намеренно. Софтом не читается, нажатие просто перезагружает SoC.

Расположение по плате: `USER` рядом с синим user-LED (`D1`, GPIOA14, управляем), `RESET` рядом с красным индикатором питания 3.3V (`LED2`, не управляется).

Vendor (Sipeed SDK) описывает кнопку идентично нам: тот же `&porta 30`, та же полярность, тот же код `KEY_DISPLAYTOGGLE`. Различие только в debounce (vendor 1 мс, у нас 10 мс) и в label.

### Чтение нажатия USER

```
# Найти input device
cat /proc/bus/input/devices | grep -A6 -i "gpio-keys"
# H: Handlers=event0  → устройство это /dev/input/event0
# B: KEY=800000000000 0 0 0 0 0 0  → выставлен бит 431 (KEY_DISPLAYTOGGLE)

# Способ 1: evtest (нагляднее всего)
evtest /dev/input/event0
# нажатие USER → EV_KEY code 431 (KEY_DISPLAYTOGGLE) value 1
# отпускание   → value 0
```

`evtest` не в EXTRA_PKGS по умолчанию, поставить отдельно:
`apt install -y --no-install-recommends evtest`

```
# Способ 2: без установки, сырое чтение (на riscv64 одно событие = 24 байта)
od -An -tx1 -w24 /dev/input/event0
# нажатие USER  → строка оканчивается на  01 00 af 01 01 00 00 00  (EV_KEY 0x1af value 1)
# отпускание    → ... af 01 00 00 00 00
# (плюс SYN-строка ... 00 00 00 00 00 00 после каждого)
```

### Привязка действия на нажатие

`gpio-keys` отдаёт только input-событие, действие вешается в userspace. В нашем
Debian-rootfs практичный путь это `triggerhappy` (демон `thd`, есть в apt),
который маппит клавишу на команду:

```
apt install -y --no-install-recommends triggerhappy
# правило: код KEY_DISPLAYTOGGLE запускает скрипт
mkdir -p /etc/triggerhappy/triggers.d
printf 'KEY_DISPLAYTOGGLE 1 /usr/local/bin/on-user-key.sh\n' \
    > /etc/triggerhappy/triggers.d/user-key.conf
systemctl enable --now triggerhappy   # либо: thd --triggers /etc/triggerhappy/triggers.d /dev/input/event0
```

Значение поля состояния это `1` нажатие, `0` отпускание, `2` autorepeat.
Различить короткое и долгое нажатие проще собственным обработчиком, который
засекает время между `1` и `0` (например читая `evtest`/`event0` в скрипте и
сравнивая дельту с порогом).

Для справки, vendor Sipeed решает ту же задачу демоном `input-event-daemon`
(buildroot-пакет `gandro/input-event-daemon`, функциональный аналог
`triggerhappy`). Его `/etc/input-event-daemon.conf` слушает `event0` и вешает
`DISPLAYTOGGLE = /etc/gui.sh`, то есть кнопка у них запускает GUI. У нас
эквивалент это `triggerhappy`, так как `input-event-daemon` в Debian не
пакетирован.

### Проверка RESET

`RESET` (SW2) это чистый hardware-reset, отдельного input-устройства для него
нет. Подтверждение это наблюдение по UART-консоли: нажатие перезагружает плату
(баннер MaskROM/FSBL/OpenSBI), а в `/proc/bus/input/devices` второго устройства
кроме `gpio-keys` (event0) не появляется.

### Проверено на железе (2026-06-03)

Регистрация устройства:

```
# dmesg | grep -i gpio-keys
[    1.952898] input: gpio-keys as /devices/platform/gpio-keys/input/input0

# cat /proc/bus/input/devices
N: Name="gpio-keys"
H: Handlers=event0
B: EV=3
B: KEY=800000000000 0 0 0 0 0 0   # выставлен бит 431 = 0x1af (KEY_DISPLAYTOGGLE)
```

USER, способ 1 (`evtest`), нажатие и отпускание:

```
# evtest /dev/input/event0
Input device name: "gpio-keys"
  Event code 431 (KEY_DISPLAYTOGGLE)
Event: time ..., type 1 (EV_KEY), code 431 (KEY_DISPLAYTOGGLE), value 1   # нажатие
Event: time ..., -------------- SYN_REPORT ------------
Event: time ..., type 1 (EV_KEY), code 431 (KEY_DISPLAYTOGGLE), value 0   # отпускание
Event: time ..., -------------- SYN_REPORT ------------
```

USER, способ 2 (сырой `od`), совпал бит-в-бит с ожидаемым:

```
# od -An -tx1 -w24 /dev/input/event0
 16 7d 20 6a 00 00 00 00 39 d7 05 00 00 00 00 00 01 00 af 01 01 00 00 00   # EV_KEY 0x1af value 1 (нажатие)
 16 7d 20 6a 00 00 00 00 39 d7 05 00 00 00 00 00 00 00 00 00 00 00 00 00   # SYN
 16 7d 20 6a 00 00 00 00 e7 22 09 00 00 00 00 00 01 00 af 01 00 00 00 00   # EV_KEY 0x1af value 0 (отпускание)
 16 7d 20 6a 00 00 00 00 e7 22 09 00 00 00 00 00 00 00 00 00 00 00 00 00   # SYN
```

RESET: нажатие перезагрузило плату (hardware-reset подтверждён). Input-события
не даёт, второго устройства в `/proc/bus/input/devices` нет.

## Программный доступ через libgpiod

C через `<gpiod.h>` (нужно `apt install libgpiod-dev`):

```c
#include <gpiod.h>
int main(void) {
    struct gpiod_chip *chip = gpiod_chip_open_by_name("gpiochip0");
    struct gpiod_line *line = gpiod_chip_get_line(chip, 26);
    gpiod_line_request_output(line, "test", 0);
    gpiod_line_set_value(line, 1);
    // ...
    gpiod_chip_close(chip);
    return 0;
}
```

Python через `python3-libgpiod` (не в EXTRA_PKGS, ставится по нужде):

```python
import gpiod
chip = gpiod.Chip("gpiochip0")
line = chip.get_line(26)
line.request(consumer="myapp", type=gpiod.LINE_REQ_DIR_OUT)
line.set_value(1)
```

## Pinmux для возврата пина в GPIO режим

Если хочется освободить пин под GPIO которая сейчас в специальной
функции, нужно изменить pinmux register на `0x3` (XGPIO function).
Например освободить GPIOA 18 от UART1 RX:

```
# Текущее значение (UART1 RX = 0x6)
busybox devmem 0x03001068
# 0x00000006

# Переключить в XGPIOA[18] (Func3 = 0x3)
busybox devmem 0x03001068 32 0x3
# теперь gpiochip0 line 18 доступна как чистый GPIO
```

Внимание: переключение pinmux на работающую функцию (например на
UART1 во время активной сессии) приведёт к потере данных. Лучше
переключать в начале boot или после deactivate функции.

## Известные ограничения

- gpiochip0..3 регистрируются всегда, даже если соответствующий power
  domain physically отсутствует на конкретной board variant. Например
  gpiochip1 (XGPIOB) на B плате существует, но XGPIOB[NN] линии могут
  не иметь backing pads (ETH PHY power domain отключён)
- Часть линий gpiochip2 (XGPIOC) принадлежит MIPI domain. На B/E без
  поднятой MIPI они не функциональны
- libgpiod tools видят 4 chip с label вида `3020000.gpio` (по адресу
  узла в DT, без человеческих имён). Используйте `-c gpiochipN`
  как primary identifier
- `gpioinfo` показывает `consumer="..."` для линий занятых kernel
  driver'ом. libgpiod не сможет request эти линии без kernel-side
  release или принудительного override (что опасно)
- libgpiod 2.x в Debian 13 trixie имеет другой синтаксис чем 1.x.
  Старые howto в интернете могут указывать `gpioset gpiochip0 22=1`,
  в 2.x это работает только с `-c gpiochip0 22=1`. См. `gpioget --help`
  и `gpioset --help` на железе

## Troubleshooting

- `gpiochip0 not found` → проверить `ls /dev/gpiochip*`. Если нет
  убедитесь что `pinctrl-sg2002` модуль (вернее built-in) активен
  через `dmesg | grep -i gpio`
- `Operation not permitted` при gpioset → libgpiod хочет root по
  дефолту. Запустите `sudo gpioset ...` или добавьте user в группу
  `gpio` если она есть
- Запись pinmux через devmem не работает → проверьте что пишете в
  правильный регистр (`docs/sg2002_pin_map.md`, колонка Pinmux register)
- USER LED не реагирует на mmc activity → проверьте `cat /sys/class/leds/
  licheerv-nano:blue:user/trigger`, должно быть `[mmc0]` в квадратных
  скобках. Если другой trigger, переключите echo
- USER button не генерирует events → проверьте `dmesg | grep gpio-keys`,
  должна быть строка о регистрации input device. Если нет ошибки —
  возможно физический контакт сломан или GPIO ACTIVE_LOW логика
  инвертирована для вашей ревизии платы

## Связанные документы

- `docs/sg2002_pin_map.md` это распиновка SoC + 2x14 header
- `docs/i2c_setup.md` это совместное использование пинов I2C ↔ GPIO
- `docs/adc_setup.md` это ADC channel
- `patches/linux/0018-licheerv-nano-user-led.patch` это USER LED pinmux + `default-state=off` + label `blue:user` (полярность active-high из upstream/0001; прежний патч 0006 ACTIVE_LOW удалён как неверный)
