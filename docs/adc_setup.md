# ADC на LicheeRV Nano

Краткая инструкция по работе с SAR-ADC SG2002 (3 канала, 12 бит,
reference 3.3V) под mainline Linux 6.18.29.

Статус: узел включён в DTS, чтение через IIO sysfs, детальная проверка
на железе не проводилась.

## Что включено в образ

- DTS узел `&saradc` (compatible `sophgo,cv1800b-saradc`,
  `reg = <0x030f0000 0x1000>`) активирован со `status = "okay"`
  во всех 4 вариантах через `patches/linux/0001-licheerv-nano-dts-
  b-e-w-extensions.patch`
- Kernel module `sophgo_cv1800b_adc` (10 KB) собран как `=m`,
  установлен в rootfs, авто-загружается через udev при probe узла
  `&saradc`
- IIO subsystem активна (`CONFIG_IIO=y`), buffer support отключён
  (single-shot чтения достаточно)

## Hardware

SAR-ADC SG2002 имеет 3 входных канала:

- channel 0: internal SoC pad (не выведен на header)
- channel 1: header pin "ADC1" (SoC pin 59, отдельный pad ADC1),
  единственный доступный пользователю
- channel 2: internal SoC pad

SoC ADC: reference voltage 3.3V на SoC pad, разрешение 12 бит,
диапазон raw `0..4095`, scale `3300 mV / 4096 = 0.806 mV/LSB`.

ВАЖНО: на плате между header pin "ADC_PIN" и SoC pad ADC1 стоит
резистивный делитель R6 10K + R10 5.1K на GND (см. schematic page 4
LicheeRV_Nano-7040{5,15,18}_Schematic.pdf, блок "Pin"):

```
header ADC_PIN ─[R6 10K]─ ADC1 (SoC 59) ─[R10 5.1K]─ GND
```

Коэффициент деления: ADC1 = header_V × 5.1 / (10 + 5.1) = header_V × 0.338.
Иначе говоря, максимальное входное напряжение на header pin которое
не насыщает ADC = 3.3 / 0.338 ≈ 9.76 V. Это расширяет полезный
диапазон для measurement battery voltage или подобных приложений.

Перевод raw в напряжение на header pin:

```
voltage_header_mV = raw × 3300 / 4096 × (10 + 5.1) / 5.1
                  = raw × 3300 × 15.1 / 5.1 / 4096
                  ≈ raw × 2.385
```

Например raw=2048 (середина диапазона) → ≈4882 mV на header pin.
raw=4095 → ≈9765 mV.

Sipeed pinout: ADC1 pin на правой стороне 2x14 header (см.
`docs/sg2002_pin_map.md` и RV_Nano_3.jpg из Sipeed wiki,
https://wiki.sipeed.com/hardware/en/lichee/assets/RV_Nano/intro/RV_Nano_3.jpg).

## Проверка что работает

```
# 1. Модуль загружен
lsmod | grep sophgo
# sophgo_cv1800b_adc

# 2. IIO device появился
ls /sys/bus/iio/devices/
# iio:device0

# 3. Driver name
cat /sys/bus/iio/devices/iio:device0/name
# sophgo-cv1800b-adc

# 4. Каналы
ls /sys/bus/iio/devices/iio:device0/
# in_voltage0_raw, in_voltage1_raw, in_voltage2_raw, in_voltage_scale,
# sampling_frequency, name, of_node, ...
```

## Чтение значений

```
# Один отсчёт каждого канала
cat /sys/bus/iio/devices/iio:device0/in_voltage1_raw
# 20 (например)

# Scale в mV/LSB
cat /sys/bus/iio/devices/iio:device0/in_voltage_scale
# 3300/2^12 ≈ 0.805 (рекомендация iio_info интерпретирует точно)

# Sampling frequency
cat /sys/bus/iio/devices/iio:device0/sampling_frequency
# например 1000
```

Перевод raw в mV на SoC pad ADC1 (внутреннее, до делителя) считается
как raw × 3300 / 4096. Формула для header pin с учётом делителя
приведена выше в разделе Hardware.

## Скриптовая обвязка

Простой polling в bash:

```sh
#!/bin/sh
# adc-read.sh: усреднение N samples из ADC1
N=${1:-10}
sum=0
for i in $(seq 1 $N); do
  v=$(cat /sys/bus/iio/devices/iio:device0/in_voltage1_raw)
  sum=$((sum + v))
done
avg=$((sum / N))
mv=$((avg * 3300 / 4096))
echo "ADC1 raw_avg=$avg mV=$mv"
```

Python пример (нужно `apt install python3-numpy` если хочется
векторных операций):

```python
import time
def read_adc_mv(channel=1, samples=10):
    path = f"/sys/bus/iio/devices/iio:device0/in_voltage{channel}_raw"
    vals = []
    for _ in range(samples):
        with open(path) as f:
            vals.append(int(f.read().strip()))
        time.sleep(0.001)
    avg = sum(vals) / samples
    return avg * 3300 / 4096

print(f"ADC1 = {read_adc_mv(1):.1f} mV")
```

## Использование на железе

ADC1 header pin принимает напряжение `0..9.76V` благодаря резистивному
делителю R6+R10 на плате. На SoC pad ADC1 при этом будет 0..3.3V.
Превышение `~10 V` на header pin может разрушить SoC pad (через
делитель пройдёт больше 3.3V).

Типичные применения:

- Потенциометр между 3V3 и GND, wiper на ADC1 пин (regulated voltage
  divider)
- Light-dependent resistor (LDR) в делителе с фиксированным резистором,
  получаем зависимость от освещения
- Battery voltage monitoring через делитель 1:2 (если battery 6V max,
  делитель доводит до 3V)
- Temperature sensor аналоговый (LM35, TMP36)

Простая проверка через потенциометр:

```
# Прокрутить потенциометр, читать значение
watch -n 0.5 cat /sys/bus/iio/devices/iio:device0/in_voltage1_raw
# raw должен меняться от 0 до 4095 при прокрутке
```

## Известные ограничения

- ADC channel 0 и 2 не выведены на header LicheeRV Nano, их значения
  отражают internal SoC pads (могут быть около VDD или GND, или
  плавающими)
- Floating ADC1 (без подключённого источника напряжения) даёт
  значения близкие к нулю или noise floor (~10-30 raw = 8-25 mV)
- Reference voltage `3300 mV` зашит в driver, не конфигурируется через DT
- ADC не имеет IIO buffer support (не нужен для single-shot), для
  high-frequency capture потребуется `CONFIG_IIO_BUFFER=y` и доработка
  driver под trigger-driven streaming
- Sampling frequency задаётся через cycle регистры, текущая не
  оптимизировалась под скорость

## Troubleshooting

- `/sys/bus/iio/devices/` пуст → проверить `lsmod | grep sophgo`,
  если модуль не загружен сделать `modprobe sophgo-cv1800b-adc`.
  Проверить `cat /proc/device-tree/soc/adc@30f0000/status` (должно
  быть `okay`)
- Все каналы возвращают одинаковое значение → driver возможно не
  переключает channel mux, проверить kernel log `dmesg | grep saradc`
- raw зависает на одном значении → возможно clock CLK_SARADC не
  тикает, проверить `cat /sys/kernel/debug/clk/clk_summary | grep
  saradc`
- `waiting_for_supplier` в sysfs → DT supplier (regulator или clock
  provider) не probed. Не блокирует чтение базово, но driver может
  работать с дефолтным reference

## Связанные документы

- `docs/sg2002_pin_map.md` это распиновка SoC + 2x14 header с ADC1 каналом
- `docs/gpio_setup.md` это GPIO subsystem
- `docs/sipeed_resources.md` это анализ ADC voltage divider R6+R10 на header
