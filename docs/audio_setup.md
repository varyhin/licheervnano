# Audio bring-up на LicheeRV Nano

Документ собирает информацию по аудио-подсистеме SG2002 + LicheeRV Nano для bring-up под mainline Linux 6.18.29. Статус на 2026-06-12: и capture (микрофон), и playback (динамик через AW8010A) работают на железе. Capture повторно подтверждён на свежем образе 2026-06-12 (gain 18, пик 12% на речи с полуметра, запись подтверждена на слух). Голос, записанный микрофоном, слышен при `aplay -D plughw:0,1` на внешнем 8Ω динамике (header VOP/VON). Усилитель включается только на время воспроизведения (стрим-гейтинг через SPK_EN, patches 0012/0013). Детали по фазам в конце документа.

> Поправка от 2026-06-01 (патч 0016). Railing на высоких ступенях gain и «плавающий L/R слот» были НЕ из-за CTUNE, а из-за гонки двух I2S-мастеров такта (контроллер I2S0 мастерил BCLK одновременно с master-only ADC). Фикс это сделать контроллер захвата clock slave (codec-master в DT 0010 + `set_fmt` управляет `BLK_MASTER_MODE`/`BCLK_OUT_FORCE_EN`, патч 0016), плюс `channels_min=2` и settle 1000мс. Патч 0014 (CTUNE) УДАЛЁН как редундантный, `scripts/pick-loud-channel.py` и `ttable` больше не нужны, слот детерминирован. Упоминания CTUNE, 0014, pick-loud и ttable ниже исторические. Авторитетный разбор зафиксирован в лабораторном журнале проекта.

## Запись с микрофона: оптимальные настройки и диагностика

Подтверждено на железе 2026-05-30. Микрофон LMA2718T421 это один аналоговый MEMS на левом входе ADC (AUD_AINL_MIC), правого микрофона на плате нет. ADC стереофонический; правый вход висит, но после фикса тактов (clock-slave, патч 0016) и settle молчит (rms ~4). Микрофон чувствительный: на максимуме gain с ~50 см левый канал почти зашкаливает (peak 99.9%), поэтому проблема записи была НЕ в железе, а в гонке тактов (устранена) и рецепте ALSA.

### Подбор громкости (gain) и запись это рабочие примеры

После фикса тактов (I2S-контроллер захвата это clock slave, внутренний ADC это clock master) захват детерминированный: микрофон всегда в ЛЕВОМ слоте кадра, правый неподключённый вход после старта тихий. Прежние заметки про «случайный слот» и `ttable` ниже относятся к до-фиксовому состоянию и больше не нужны.

Усиление это аналоговый PGA, kcontrol `numid=1`: диапазон 0..24 шагом 2 dB (0..+48 dB). Регулятор монотонный, каждые +2 ступени примерно удваивают уровень, без рывков и без railing.

Подобрать оптимальный gain под свою дистанцию (говорить ровно во время каждой из пяти записей):

```bash
cat > /tmp/gainsweep.sh <<'EOF'
for g in 16 18 20 22 24; do
  amixer -c0 cset numid=1 $g,$g >/dev/null 2>&1
  arecord -D hw:0,0 -c2 -r48000 -fS16_LE -d 4 /tmp/g.wav >/dev/null 2>&1
  tail -c +45 /tmp/g.wav | od -An -v -td2 -w4 | awk -v g=$g '
    {n++; a=$1<0?-$1:$1; if(a>p)p=a; s+=$1*$1}
    END{printf "gain %2d: peak=%d (%.0f%%) rms=%.0f (%.0f%%)\n", g, p, 100*p/32768, sqrt(s/n), 100*sqrt(s/n)/32768}'
done
EOF
bash /tmp/gainsweep.sh
```

Правило выбора: брать самый большой gain, при котором пик на самой громкой речи держится около 50-70% и НИКОГДА не упирается в 100% (32768). Это запас на пики без клиппинга.

Замер на железе, речь с 30-50 см:

| gain | peak | rms |
|---|---|---|
| 16 | 7% | 1% |
| 18 | 12% | 2% |
| 20 | 18% | 3% |
| 22 | 28% | 5% |
| 24 | 43% | 8% |

Вывод по дистанции:
- близко 30-50 см: gain 24 (пик 43%, без клипа, самый громкий аналог).
- громче или ближе ~20 см: снизить до 20-22, иначе пики клиппят.
- 2 м и дальше: gain 24, аналога уже мало.

Про уровень: аналог упирается в +48 dB (gain 24), поэтому даже вблизи rms умеренный (~8%). Это физика тракта, не настройка. Для более громкой записи поверх gain 24 нужен цифровой makeup (×1.5-2 поднимает пик 43% до ~86% без клиппинга) или софтовый AGC, это уже постобработка.

Запись и воспроизведение, рабочие примеры:

```bash
# выставить выбранный gain (пример: 24)
amixer -c0 cset numid=1 24,24

# записать моно: микрофон это левый слот. Берём через plughw (он держит
# родной 2-канальный кадр и сводит в моно софтом). Прямой hw:0,0 -c1 нельзя
# это железо всегда формирует 2 слота, и 1-канальное открытие ломает кадр.
arecord -D plughw:0,0 -c1 -r48000 -fS16_LE -d 5 /tmp/mic.wav

# проиграть на динамик: он на правом выходе DAC (AUD_AOUTR), моно
# апмиксится в оба канала, правый дотягивается до динамика.
aplay -D plughw:0,1 /tmp/mic.wav
```

Запись до ручной остановки (вместо `-d 5`): `arecord -D plughw:0,0 -c1 -r48000 -fS16_LE /tmp/mic.wav`, стоп по Ctrl-C.

### Что предустановлено в образе

Из аудио в образе предустановлен только пакет `alsa-utils` (`amixer`/`arecord`/`aplay`). Конфигов и сервисов нет сознательно. Прежняя схема, а именно target сборки `audio-install`, `/etc/asound.conf` с устройствами `mic`/`spk` и сервис `set-audio-gain.service`, удалена 2026-06-01 вместе с фиксом clock-slave (патч 0016). Аудио не стартует на boot, рецепт запускается вручную. После загрузки усиление ADC равно `0,0`, поэтому перед записью его нужно выставить.

Готовые команды на плате сразу после boot (проверено на свежем образе 2026-06-12, запись подтверждена на слух):

```
amixer -c 0 cset numid=1 18,0
arecord -D plughw:0,0 -c 1 -r 48000 -f S16_LE -d 5 /tmp/mic.wav
aplay -D plughw:0,1 /tmp/mic.wav
```

Раздел ниже описывает, как при желании завести алиас `mic` вручную и как диагностировать тракт.

### Рабочий рецепт (ручная сборка)

Самый простой и проверенный на железе путь это запись напрямую через `plughw`, конфиг не нужен:

```
arecord -D plughw:0,0 -c 1 -r 48000 -f S16_LE /tmp/mic.wav
```

`plughw:0,0` держит карту в родном стерео-кадре и сводит в моно. Правый вход после фикса тактов (clock-slave, патч 0016) и settle молчит, поэтому downmix чистый. Эквивалентно можно писать сырое стерео и слушать левый канал: `arecord -D hw:0,0 -c 2 ...`.

Для удобства можно завести именованное устройство `mic` (это ровно `plughw:0,0`):

```
cat > /etc/asound.conf <<'EOF'
pcm.mic {
  type plug
  slave.pcm "hw:0,0"
}
EOF
```

после чего работает `arecord -D mic -c 1 -r 48000 -f S16_LE out.wav`.

ВАЖНО (проверено на железе 2026-05-30): НЕ использовать `ttable.0.0 1.0` под `type plug`. Раньше так и было прописано, но `type plug` НЕ применяет ttable для capture, и устройство `mic` выдавало ТИШИНУ (peak 7, 0.0% VU). Именно этот рецепт создавал иллюзию «тихого/сломанного микрофона», хотя сам мик исправен. Простой `type plug` без ttable работает.

Проверить, что файл на месте:

```
cat /etc/asound.conf
```

Усиление и команда записи:

```
amixer -c 0 cset numid=1 18,0
arecord -D mic -c 1 -r 48000 -f S16_LE /tmp/mic.wav
```

- `numid=1 Internal I2S Capture Volume` это аналоговый PGA, диапазон 0..24 = 0..+48 dB шагом 2 dB. Рабочий дефолт это 18 (+36 dB): чистый, слышен на динамике. `,0` ставит правый канал в минимум (правый вход не подключён, минимум на нём держит downmix чище).
- НЕ использовать gain 20 (`0xA800`): точечно нестабилен, даёт railing/тишину даже после фикса clock-slave (патч 0016). Чистые ступени: …14, 16, 18, 22. Громкий близкий источник может клиппить на пиках это снизить до 14-16.
- Историческая заметка: railing высоких ступеней gain (≥16) сначала атрибутировали неподстроенной тактовой ADC и лечили CTUNE-патчем 0014 (замер 2026-05-29 выглядел успешным). Настоящей причиной была гонка двух I2S-мастеров такта, устранена патчем 0016 (clock slave), патч 0014 удалён как редундантный. Подробности ниже в разделе про подбор gain.

### Почему именно так

- Сырое моно через `hw:0,0 -c 1` даёт щелчки: кодек жёстко формирует 2-канальный I2S-кадр (`CV1800B_RXADC_CHANNELS=2`), а контроллер настраивается на 1 слот, BCLK расходится вдвое, кадровая синхронизация плывёт. Поэтому моно берут через `plughw` (родной стереокадр + downmix), а не через сырой `hw:0,0 -c 1`.
- `plughw:0,0 -c 1` держит родной стереокадр (щелчков нет) и сводит L+R. Раньше боялись «шума висящего правого входа», но после CTUNE-фикса (patch 0014) правый вход молчит (rms ~4), поэтому downmix чистый.
- ttable для capture НЕ работает под `type plug` (даёт тишину, проверено на железе). Полное исключение правого канала через `type route` теоретически возможно, но не нужно: правый и так молчит, а downmix `plughw` уже чистый. Канонический способ это `arecord -D plughw:0,0 -c 1` (или алиас `mic` = простой `type plug`).

### Диагностика и поиск максимального gain (свип)

Сначала посмотреть оба канала раздельно (видно, что правый рельсит):

```
arecord -Dhw:0,0 -c 2 -r 48000 -f S16_LE -V stereo -d 5 /dev/null
```

Левая полоска VU это микрофон (на близком источнике почти зашкаливает), правая молчит (после CTUNE-фикса висящий правый вход тих, rms ~4).

Найти максимальный gain без клиппинга простым свипом (метр в реальном времени, файл не нужен, пишем в `/dev/null`):

```
for g in 18 19 20 21 22; do
  amixer -c 0 cset numid=1 $g >/dev/null
  echo "=== gain=$g ==="
  arecord -D plughw:0,0 -c 1 -r 48000 -f S16_LE -V mono -d 3 /dev/null
done
```

Взять самое большое значение, при котором на обычной речи полоска НЕ долетает до MAX.

Важно (исправлено 2026-06-01): ранее railing на верхних ступенях gain (comb-volume прыгал 0xB000 → 0xE400) списывали на неподстроенную тактовую ADC, и патч `patches/linux/0014` ставил `RXADC_ANA3 CTUNE` по MCLK. На железе выяснилось, что это была мисатрибуция: настоящая причина railing это гонка двух I2S-мастеров такта, устранённая переводом контроллера в clock-slave (патч 0016). Патч 0014 удалён как редундантный (CTUNE=0xC это аппаратный сброс-дефолт). Рабочий дефолт gain это 18, точечную нестабильность на gain 20 (`0xA800`) не использовать.

### Проверка, что сигнал живой

```
dd if=/tmp/mic.wav bs=1 skip=44 2>/dev/null | od -An -tx2 -w2 | sort -u | wc -l
```

Тысячи уникальных значений это реальный звук. Единицы значений это тишина или нули (проблема тракта, например неправильный I2S).

## Hardware-аудио тракт

На плате есть встроенный аналоговый codec в SoC и два внешних компонента: MEMS-микрофон и audio-amp. Весь тракт **аналоговый** на границе SoC, цифровая сторона это I2S0 внутри SoC между CPU и встроенным codec.

```
+------------+   analog mic   +-------------------+ I2S0  +--------+
| LMA2718T421| -------------- | SG2002 internal  | <---->| ARM    |
|  MEMS mic  |  AUD_AINL_MIC  | analog ADC+DAC   |       | core   |
+------------+                | (codec)           |       +--------+
                              |                   |
                              | AUD_AOUTR         |
                              +---------+---------+
                                        |
                                        v analog audio out
                              +-------------------+ BTL +-----------+
                              | AW8010A           |---->| Speaker   |
                              | Class-D mono amp  |---->| 8 ohm     |
                              +-------------------+     +-----------+
```

### LMA2718T421-OA5-2 MEMS микрофон

| Параметр | Значение |
|---|---|
| Тип | Analog electret-equivalent MEMS |
| Output | Single-ended analog, ~10 mV/Pa typical |
| Power | 1.8V–3.3V |
| Подключение | AUD_AINL_MIC pin SoC (с DC-block cap) |
| Datasheet | архив Sipeed downloads, `07_Datasheet/Onboard_Components/C7587901_MEMS麦克风_LMA2718T421-OA5-2_规格书_WJ437848.PDF` |

Это аналоговый MEMS, не PDM-digital. Подключается напрямую к встроенному ADC SoC через cap.

### AW8010A audio amplifier

| Параметр | Значение |
|---|---|
| Тип | Class-D mono BTL amplifier |
| Power | 2.5V-5.5V VDD, в схеме VSYS (5V от USB) |
| Input | Differential INP/INN |
| Output | BTL VO_P/VO_N, выведены на 2x14 header (динамик внешний) |
| Enable | EN pin (нужен GPIO для включения) |
| Datasheet | архив Sipeed downloads, `07_Datasheet/Onboard_Components/Awinic-AW8010A_EN_V1.2.pdf` |

Не имеет I²C/I²S, только аналоговый сигнал + enable. Управление полностью через один GPIO (HIGH=enabled). С точки зрения mainline это `simple-amplifier` driver с enable-GPIO.

### Динамик внешний (не на плате)

На LicheeRV Nano динамика **нет** припаянного. AW8010A это только усилитель, его BTL-выходы `VO_P/VO_N` выведены на 2x14 header как label `VOP / VON`. По schematic 70418:

| Header pin | Сигнал | Назначение |
|---|---|---|
| Left side pos 4 | GPIOA 15 (SoC pin 17, pad `SPK_EN`) | Likely **AW8010A enable** для включения амплифа |
| Left side pos 5 | VOP | AW8010A Class-D positive output |
| Left side pos 6 | VON | AW8010A Class-D negative output |

Нумерация позиций сверху-вниз по левой гребёнке header (рядом с USB-C коннектором). Полная распиновка см. `docs/sg2002_pin_map.md`.

Для bring-up audio нужно:
1. Прокинуть GPIOA[15] HIGH через DT-узел или `gpioset` для активации амплифа.
2. Подключить провода динамика к header pins VOP + VON.

Что нужно подключить:

| Параметр | Значение |
|---|---|
| Тип | Micro-speaker / piezo / small dynamic driver |
| Impedance | 8 Ω (рассчитан AW8010A) |
| Power | до 1 Вт (от 5V VSYS Class-D output) |
| Подключение | 2 провода: VO_P + VO_N (полярность некритична для класс-D BTL) |
| Цена | ~50-200 руб на маркетплейсах |

Примеры подходящих:
- Магнитоэлектрический micro-speaker 8Ω 0.5W ∅20-30мм
- Динамик от старого мобильного телефона / mp3-плеера
- Piezo-зуммер для уведомлений (не музыки)

Из Sipeed wiki (https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/1_intro.html):
> Audio Output: Onboard PA amplifier, can directly connect speakers under 1W

Возможна path B через PicoClaw expansion board (https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/7_picoclaw_board.html) которая имеет встроенный speaker connection. Без неё нужен прямой провод от header к динамику.

Уточнение по pin_map.md. По схеме 70418 пины VOP/VON на header это speaker output от AW8010A (Class-D), не MIPI DSI. Прежняя ошибка в `docs/sg2002_pin_map.md` (VOP/VON как DSI video output) исправлена, таблица header и список свободных пинов согласованы с этим документом.

### SG2002 встроенный codec

Из vendor DTS (`build/boards/default/dts/cv180x/cv180x_base.dtsi` в vendor SDK sipeed/LicheeRV-Nano-Build) и TRM:

| Блок | MMIO base | Длина | Compatible | Назначение |
|---|---|---|---|---|
| Analog ADC (mic input) | `0x0300A100` | 0x100 | `cvitek,cv182xaadc` | Внутренний ADC, моно, до 48kHz |
| Analog DAC (speaker out) | `0x0300A000` | 0x100 | `cvitek,cv182xadac` | Внутренний DAC, моно, до 48kHz |
| PDM controller | `0x041D0C00` | 0x100 | `cvitek,cv1835pdm` | Не используется (наш mic аналоговый) |
| I²S3 (clock source) | `0x04130000` | 0x100 | `cvitek,cv1835-i2s` | Источник MCLK для codec |

Pin map из schematic:

| SoC pin | Альтернативы | Подключено к |
|---|---|---|
| AUD_AINL_MIC | XGPIOC[23] / IIS1_BCLK / IIS2_BCLK | LMA2718T421 (mic) |
| AUD_AOUTR | XGPIOC[24] / IIS1_DI / IIS2_DO / IIS1_DO | AW8010A INP/INN (speaker amp) |
| PAD_AUD_AVREF | это | Внешняя bias-сеть |
| VDD18A_AUD | это | 1.8V analog supply |
| VSS18A_AUD | это | analog GND |

В bring-up для audio эти pins должны остаться в default-функции (analog audio), не переключаться в GPIO/I²S.

## Vendor SDK driver inventory

`linux_5.10/sound/soc/cvitek/` в vendor SDK sipeed/LicheeRV-Nano-Build (пин в manifest/sources.mk):

| Файл | Размер | Назначение | Backport приоритет |
|---|---|---|---|
| `cv181xadc.c` | 976 строк | ADC codec driver (наш ADC) | критично |
| `cv181xdac.c` | 746 строк | DAC codec driver (наш DAC) | критично |
| `cv181x_cv181xadc.c` | 289 | Machine driver: I²S0 ↔ ADC card | критично |
| `cv181x_cv181xdac.c` | 246 | Machine driver: I²S0 ↔ DAC card | критично |
| `cv1835_i2s.c` | 1355 | I²S controller (включая I²S3 для MCLK codec) | критично (clock provider) |
| `cv1835_i2s_subsys.c` | 350 | I²S top-level subsys + i2s_mclk clk | критично |
| `cv1835pdm.c` | 280 | PDM controller (не используется) | пропустить |
| `cv182x_cv182xpdm.c` | 99 | PDM machine (не используется) | пропустить |
| `dummy_codec.c` | 153 | Dummy codec для testing | опционально |
| `cv1835_lt9611.c` | 122 | HDMI codec (для LCD/HDMI) | не используется |
| `cv1835_adau1372.c` | 209 | Внешний ADAU1372 codec (не наш случай) | пропустить |

Compatible strings, найденные в vendor:

| Compatible | Driver | Что |
|---|---|---|
| `cvitek,cv182xaadc` | cv181xadc.c | ADC core codec |
| `cvitek,cv182xadac` | cv181xdac.c | DAC core codec |
| `cvitek,cv182xa-adc` | cv181x_cv181xadc.c | machine driver ADC |
| `cvitek,cv182xa-dac` | cv181x_cv181xdac.c | machine driver DAC |
| `cvitek,i2s_tdm_subsys` | cv1835_i2s_subsys.c | I²S subsys, MCLK provider |

Note: cv181x family names в vendor SDK означает «cv181x board» это же что и наш cv180x/SG2002 (внутренняя нумерация Sophgo). Mainline компилирует это под `ARCH_SOPHGO` и compatible `sophgo,cv1800b` / `sophgo,sg2002`.

## Что есть в mainline 6.18.29

| Слой | Файл/компонент | Состояние |
|---|---|---|
| ALSA core | `sound/core/` | есть |
| ASoC framework | `sound/soc/` | есть |
| DesignWare I²S | `sound/soc/dwc/dwc-i2s.c` | есть (используется на других SoC) |
| Simple-audio-card | `sound/soc/generic/simple-card.c` | есть |
| Simple-amplifier | `sound/soc/codecs/simple-amplifier.c` | есть, подходит для AW8010A |
| Sophgo audio drivers | `sound/soc/sophgo/` | **нет**, директории не существует |
| cv180x audio DT-узлы | `cv180x.dtsi` | **нет** ADC/DAC/I²S узлов |
| Kernel config audio | `defconfig` | `SND_SOC=n`, никакие codec не включены |

Итого: всё что относится к SG2002-specific audio это нужно backport. Mainline-side только framework.

## Backport-объём

| Этап | Что | Объём кода |
|---|---|---|
| 1. I²S subsys + I²S3 clock provider | cv1835_i2s_subsys.c, частично cv1835_i2s.c | ~1500 строк |
| 2. ADC codec | cv181xadc.c (+ заголовки) | ~1100 строк |
| 3. DAC codec | cv181xdac.c (+ заголовки) | ~850 строк |
| 4. ADC machine driver | cv181x_cv181xadc.c | ~290 строк |
| 5. DAC machine driver | cv181x_cv181xdac.c | ~250 строк |
| 6. AW8010A control | simple-amplifier через GPIO | ~10 строк DTS |
| 7. DT-узлы в cv180x.dtsi | adc@0300A100, dac@0300A000, i2s@04130000, sound_adc, sound_dac | ~40 строк DTS |
| 8. Kernel config | SND_SOC + SOPHGO codec configs | ~10 строк Makefile |

Итого: ~4000 строк vendor C-кода + ~50 строк DTS + ~10 строк config. Сопоставимо по сложности с aic8800-vendor backport (commit `a086fe536`).

## Зависимости и риски

### Зависимости

- Vendor код использует `linux_5.10` API. Mainline `6.18.29` имеет различия в:
  - ASoC API (`snd_soc_dai_ops`, `snd_soc_component_driver` изменения)
  - clock framework
  - GPIO API
  - регулятор API
- Compat-layer через `patches/<comp>/0001-mainline-compat.patch` или ccflags include header (паттерн [[kernel-backport-compat-pattern]] из memory).

### Риски

1. **Регистровая карта**. Vendor использует абсолютные адреса (`0x0300A100`). Эти адреса для SG2002 в TRM v1.0-alpha (стр. 88-91 для analog codec). Сверить с TRM перед написанием DT.
2. **Clock dependencies**. Codec требует MCLK от I²S3. Если I²S subsys driver не работает, codec тоже не работает. Возможно зацикленная зависимость DT.
3. **Pinmux**. Pins `AUD_AINL_MIC` и `AUD_AOUTR` должны быть в analog-функции (default reset state). Если что-то перевело их в GPIO/I²S, нужно вернуть.
4. **Mainline ASoC API**. Vendor драйверы могут использовать deprecated API. Backport может требовать переписать машин-драйверы под новый API.
5. **AW8010A enable GPIO**. В schematic нужно найти точно какой GPIO управляет EN pin усилителя (через pdfplumber или ручной разбор PDF).

## Открытые вопросы для следующих фаз (исторический архив, фазы завершены)

1. Какой GPIO управляет EN pin AW8010A? (Phase 2 это найти в schematic).
2. MCLK от I²S3 или есть альтернативный clock source (например осциллятор SoC)?
3. Достаточно ли только cv181xadc.c + cv181xdac.c, или нужен ещё `codecs/cv181xadac.h` (header) с register definitions?
4. Какой sample rate поддерживает встроенный codec? Vendor wiki показывает 48000 Hz, нужно подтвердить по TRM.
5. Есть ли DMA для audio (если да, нужен DMA channel в DT)?

## Команды для следующих фаз (исторический архив, фазы завершены)

Пути `<vendor-sdk>` ниже это локальный checkout sipeed/LicheeRV-Nano-Build.

### Phase 2: DT-узлы + pinmux

```
# Изучить vendor DTS, скопировать audio nodes в cv180x.dtsi
cat <vendor-sdk>/build/boards/default/dts/cv180x/cv180x_base.dtsi | grep -A6 'adc\|dac\|i2s_'

# Добавить в cv180x.dtsi
# - i2s3@04130000 controller + clock provider
# - adc@0300A100 codec
# - dac@0300A000 codec
# - sound_adc, sound_dac machine devices
```

### Phase 3: Vendor driver backport

```
# Скопировать в src/linux/sound/soc/sophgo/
mkdir -p src/linux/sound/soc/sophgo
cp <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv181xadc.c \
   <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv181xdac.c \
   <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv181x_cv181xadc.c \
   <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv181x_cv181xdac.c \
   <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv1835_i2s_subsys.c \
   <vendor-sdk>/linux_5.10/sound/soc/cvitek/cv1835_i2s.c \
   src/linux/sound/soc/sophgo/

# Создать Kconfig + Makefile + compat-header
# Применить patches/linux/0008-sophgo-audio.patch
```

### Phase 4: Userspace тест

```
# Установить ALSA утилиты в rootfs
apt-get install -y alsa-utils

# На плате после boot:
cat /proc/asound/cards    # должны быть карты с ADC и DAC
amixer -Dhw:0 cset name='ADC Capture Volume' 24
arecord -Dhw:0,0 -d 3 -r 48000 -f S16_LE -t wav /tmp/test.wav
aplay -D hw:1,0 /tmp/test.wav
```

## Текущий статус

**Phase 1 (Discovery)** завершена. Собраны:
- Hardware-карта пинов и компонентов
- Vendor SDK driver list + DT bindings
- Mainline gap analysis
- Объём backport (~4000 строк)

**Phase 2 (DT-узлы) v2** завершена. После обнаружения mainline upstream работы переделана под mainline bindings. Patch `patches/linux/0008-licheerv-nano-audio-dt-nodes.patch` добавляет в cv180x.dtsi:
- `dma-router@154` (label dmamux, sophgo,cv1800b-dmamux) внутри `syscon@3000000` это DMA router
- `i2s0@4100000`, `i2s1@4110000`, `i2s2@4120000`, `i2s3@4130000` это все 4 TDM/I2S controllers (sophgo,cv1800b-i2s)
- `audio-codec@300a100` (label sound_adc, sophgo,cv1800b-sound-adc) это ADC codec для микрофона
- `audio-codec@300a000` (label sound_dac, sophgo,cv1800b-sound-dac) это DAC codec для динамика
- PDM controller не добавлен (не нужен mainline)

Все узлы со `status = "disabled"`, dtbs компилируются без warnings.

**Phase 3 (driver backport)** завершена. Patch `patches/linux/0009-sound-soc-sophgo-cv1800b-audio-drivers.patch` импортирует mainline drivers из commit 75ca8602 (2026-01-28, после v6.18.x stable freeze):
- `sound/soc/sophgo/cv1800b-tdm.c` 716 строк (I2S/TDM controller)
- `sound/soc/sophgo/cv1800b-sound-adc.c` 322 строки (ADC codec)
- `sound/soc/sophgo/cv1800b-sound-dac.c` 208 строк (DAC codec)
- `sound/soc/sophgo/Kconfig` + `Makefile`
- Wire-up: `sound/soc/Kconfig` + `sound/soc/Makefile` это добавлен sophgo/

Kernel configs в Makefile проекта:
- `CONFIG_SND_SOC_CV1800B_TDM=m`
- `CONFIG_SND_SOC_CV1800B_ADC_CODEC=m`
- `CONFIG_SND_SOC_CV1800B_DAC_CODEC=m`
- `CONFIG_SND_SOC_SIMPLE_CARD=m` (для связывания codec + I2S)

Все 3 модуля собраны и установлены в `rootfs/trixie/lib/modules/6.18.29/kernel/sound/soc/sophgo/`. Mainline approach был выбран вместо vendor backport (3x меньше кода: 1246 строк mainline vs 3970 vendor).

**Phase 4 (board DTS activation)** завершена. Patch `patches/linux/0010-licheerv-nano-audio-activate.patch` активирует audio в DTS всех 4 board вариантов (B/E/W/WE):
- `&dmac { okay };` + `&dmamux { okay };` (DMA + router)
- `&i2s0 { okay };` (RX, capture к internal ADC)
- `&i2s3 { okay };` (TX, playback к internal DAC)
- `&sound_adc { okay };` (mic codec) + `&sound_dac { okay };` (speaker codec)
- Узел `sound` это simple-audio-card с двумя DAI-link: i2s0↔sound_adc (capture) и i2s3↔sound_dac (playback), `mclk-fs = <256>`, `system-clock-frequency = <12288000>`

Routing критичен: на SG2002 I2S0 разведён жёстко на внутренний ADC, I2S3 на внутренний DAC. I2S1/I2S2 это для внешних кодеков. Попытка использовать i2s1 для микрофона даёт запись чистых нулей.

**Phase 5 (capture) работает на железе (2026-05-28).** ALSA card `licheervnano` создаётся, микрофон LMA2718T421 пишет реальный сигнал (подтверждено: тысячи уникальных сэмплов вместо нулей).

**Микрофон это моно на левом канале.** Схема подтверждает один вход AUD_AINL_MIC, правого микрофона нет. Рабочая запись (проверено на железе 2026-05-30, звучит отлично):
```
amixer -c 0 cset numid=1 22,0    # left +44dB, right в минимум; диапазон 0..24 = 0..+48dB шаг 2dB
arecord -D plughw:0,0 -c 1 -r 48000 -f S16_LE -d 5 /tmp/mic.wav
```
`plughw` держит железо в родном стерео-кадре и сводит в моно (правый вход после фикса тактов clock-slave 0016 молчит, downmix чист). НЕ использовать `ttable.0.0 1.0` под `type plug`: для capture он игнорируется и устройство выдаёт тишину. Мик чувствительный, близкая речь клиппит на высоком gain (даёт треск) это для близи снижать gain до 10-14, для ~2 м держать 22-24.

**Известные ограничения:**
- mainline cv1800b drivers поддерживают только fixed 48 kHz, S16_LE.
- Сообщение `dw_axi_dmac ... apb_regs not initialized` безвредно (KeemBay-путь, канал берётся через dmamux). Приглушено до dev_dbg в `patches/linux/0011`.

**AW8010A enable (GPIOA[15]=SPK_EN)** в DT и стрим-гейтится драйвером (patches 0012 DT + 0013 драйвер): `spk-en-gpios` у `&sound_dac`, драйвер `cv1800b-sound-dac` поднимает линию в `.trigger` START и опускает в STOP. Ручной `gpioset` не нужен (и не сработает: линию держит kernel-consumer `spk-en`, userspace даёт `-EBUSY`). Проверено на железе WE 2026-06-09: линия 15 = 0 в покое, 1 во время `aplay`, 0 после. Методика чтения уровня (через `devmem` EXT_PORTA / `debugfs`) в `audio_spk_en_hw_test.md`.

**Playback hardware test** программно пройден: `aplay -D plughw:0,1` rc=0, DAC+DMA+I2S3 рабочий, гейтинг SPK_EN подтверждён на железе. Осталось только услышать звук на внешнем 8Ω speaker (header VOP/VON), сам динамик пока не подключали.

## Инициализация микрофона: карта регистров RXADC по источникам

Раздел сводит запуск внутреннего ADC (микрофон) по регистрам во всех известных
источниках, чтобы не перечитывать vendor SDK при каждой правке. База блока RXADC
это `0x0300A100`. Vendor задаёт смещения через `(0x1XX - 0x100)`, поэтому они
байт-в-байт совпадают с нашими.

Источники:

- Vendor SDK (эталон) это `cv181xadc.c` + карта регистров `codecs/cv181xadac.h` + функция сброса в `cv1835_i2s_subsys.c` (`cv182xa_reset_adc`). Вариант `cv182xadc.c` для 48 kHz даёт те же значения.
- Mainline pristine (то, что в ядре) это драйвер Anton Stavinskii из `torvalds/linux` commit `75ca8602`, импортирован патчем `patches/linux/0009`.
- Наш рабочий драйвер это `src/linux/sound/soc/sophgo/cv1800b-sound-adc.c` = 0009 + 0015 (soft-reset) + 0016 (clock-slave) + экспериментальные добавки в дереве (enable в prepare, SDM-init, ECO). Патч 0014 (CTUNE) удалён 2026-06-01 как редундантный, драйвер CTUNE не программирует.

### Соответствие имён и битовых полей

| Наш регистр | Off | Vendor имя | Ключевые биты |
|---|---|---|---|
| CV1800B_RXADC_CTRL0 | 0x00 | AUDIO_PHY_RXADC_CTRL0 | b0 RXADC_EN, b1 I2S_TX_EN |
| CV1800B_RXADCC_CTRL1 | 0x04 | AUDIO_PHY_RXADC_CTRL1 | b[1:0] CIC_OPT, b2 CHN_SWAP, b3 SINGLE, b[6:4] DCB_OPT, b8 IGR_INIT, b9 CLK_FORCE_EN |
| CV1800B_RXADC_STATUS | 0x08 | AUDIO_PHY_RXADC_STATUS | RO: b0 CIC0_INIT_DONE, FIR_*_DONE, b[10:8] FSM |
| CV1800B_RXADC_CLK | 0x0c | AUDIO_PHY_RXADC_CLK | b0 CLK_INV, b[15:8] SCK_DIV, b[23:16] DLYEN |
| CV1800B_RXADC_ANA0 | 0x10 | AUDIO_PHY_RXADC_ANA0 | b[15:0] gain L (COMB_LEFT), b[31:16] gain R (COMB_RIGHT) |
| CV1800B_RXADC_ANA2 | 0x18 | AUDIO_PHY_RXADC_ANA2 | b0 MUTEL, b1 MUTER, b16 DIFF_EN, b17 TRISTATE |
| CV1800B_RXADC_ANA3 | 0x1c | AUDIO_PHY_RXADC_ANA3 | b[11:8] CTUNE, b12 EN_DITHER, b13 RSTSDM, b14 EN_VCMT, b[19:16] VLDO |

### Что пишется в каждый регистр при старте (48 kHz, MCLK 12.288 МГц)

| Регистр | Vendor cv181x/cv182x | Mainline pristine (в ядре) | Наш патченый src |
|---|---|---|---|
| RXADC_CTRL0 | в `prepare`: `\|= RXADC_EN \| I2S_TX_EN`; в `shutdown` сбрасывает; `trigger` пуст («adc on до i2s reset») | в `trigger START`: оба бита=1; `STOP`: =0 | в `prepare` И в `trigger START`: оба=1; `STOP`: =0 |
| RXADCC_CTRL1 | `probe`: `\|= IGR_INIT` (b8); `hw_params`: CIC_OPT по rate (48k → CIC_DS_64) | `hw_params`: IGR_INIT=1, CIC_OPT=DECIMATION_64 (0) | как mainline (IGR_INIT=1, CIC=64) |
| RXADC_STATUS | только чтение (suspend save/restore) | не трогается | только чтение (dev_info дампы) |
| RXADC_CLK | `hw_params`: `SCK_DIV(4) \| DLYEN(0x19)` | `hw_params`→`setbclk_div`: SCK_DIV=bclk_div (=3), DLYEN=0x19 | то же (SCK_DIV, DLYEN); CTUNE не пишется (0014 удалён) |
| RXADC_ANA0 | gain через ioctl/kcontrol; `prepare` переписывает тем же значением после reset | gain через kcontrol; `hw_params` не трогает | gain через kcontrol; `hw_params` re-commit после soft-reset |
| RXADC_ANA2 | mute через ioctl/kcontrol; `prepare` переписывает после reset | маски есть, контрола нет, не пишется | `hw_params` re-commit после soft-reset |
| RXADC_ANA3 | `hw_params`: CTUNE по MCLK (48k → 0xC); DITHER/RSTSDM/VCMT не трогает | НЕ трогается (нет CTUNE) | CTUNE не программируется (0014 удалён, 0xC это сброс-дефолт); эксп. `prepare`: VCMT+DITHER on, RSTSDM hold 150 мс → release |

### Связанные регистры вне блока RXADC

| Адрес | Что | Vendor | Mainline pristine | Наш src |
|---|---|---|---|---|
| `0x0300A020` b0 ADDI_TXDAC | «ECO», коэф. усиления аналога в DAC-блоке | `hw_params`: clear b0 (GAIN_RATIO_1) на каждый rate | не трогает | эксп.: clear b0 в `hw_params` |
| `0x03003008` b29 (active-low) | soft-reset ADC (`CV182XA_ADC_RESET=0xDFFFFFFF`, `~=BIT(29)`) | `cv182xa_reset_adc()` в `shutdown` + по ioctl; импульс clear→set | нет | 0015: тот же импульс в `hw_params` + recommit ANA2/ANA0 |
| I2S3 CLK_CTRL0/1 | подача и деление MCLK | codec сам: `aud_en`+`mclk_out_en` (startup), `mclk_div` (set_mclk) | через `cv1800b-tdm` + clk framework | через `cv1800b-tdm` + clk framework |

### Порядок операций по фазам ASoC

| Фаза | Vendor | Mainline pristine | Наш src |
|---|---|---|---|
| probe | IGR_INIT в CTRL1, ioremap I2S3 | ioremap regs | + ioremap reset-рег `0x03003008` |
| startup | `clk_on` (I2S3) | это | это |
| hw_params | set_mclk → CTRL1(CIC)+ANA3(CTUNE)+CLK(SCK/DLY)+DAC ANA0(ECO) | CLK(SCK/DLY)+CTRL1(IGR+CIC) | soft-reset → recommit ANA2/ANA0 → CLK(SCK/DLY) → CTRL1 → ECO |
| prepare | recommit ANA2/ANA0 → `adc_on` (CTRL0) | нет prepare | `adc_on` (CTRL0) → SDM-init (ANA3, 2×150 мс) |
| trigger | пусто (специально) | START→enable, STOP→disable | START→enable (повторно), STOP→disable |
| shutdown | off → `reset_adc` (b29) → `clk_off` | нет | нет (reset перенесён в hw_params) |

### Чем наш src реально отличается от vendor

Значения регистров для 48 kHz у нас и у vendor совпадают: CLK SCK_DIV=3 + DLYEN=0x19,
CIC=64, CTUNE=0xC, ECO clear b0, reset-импульс b29. Различается только фаза записи и
два экспериментальных добавления.

Совпадает (просто другая фаза):

- soft-reset b29: vendor делает в `shutdown` (после потока), мы в `hw_params` (до потока). Эффект эквивалентен это чистый модулятор к старту захвата.
- recommit ANA0/ANA2: vendor в `prepare`, мы в `hw_params`. Оба после reset.
- enable CTRL0 в `prepare`: есть и там, и у нас.

Есть только у нас (экспериментально, не у vendor):

- SDM-init в `prepare`: `EN_VCMT | EN_DITHER`, затем hold `RSTSDM` 150 мс и release + ещё 150 мс. Vendor-codec биты DITHER/RSTSDM/VCMT не трогает совсем. Это зона saga 0016, на железе как победитель не закрепилась.
- Повторный enable CTRL0 в `trigger START` (у vendor `trigger` пуст, enable только в `prepare`).
- Диагностические `dev_info` дампы регистров.

Вывод для «vendor-точного» варианта: убрать SDM-блок и повторный enable, опционально
перенести reset в `shutdown`, а recommit ANA0/ANA2 в `prepare`. Тогда регистровый тракт
будет байт-в-байт vendor. Слот L/R и детерминизм модулятора vendor в codec-драйвере
не решает, у нас это закрыто софтом (`plughw` downmix; после фикса clock-slave слот детерминирован и pick-loud не нужен).

## Связанные документы

- `docs/usb_setup.md` это похожий по структуре bring-up для USB
- архив Sipeed downloads (`LicheeRV_Nano.7z`) это schematic и datasheets платы
- TRM SG2002 (`SG2002_TRM_V1.0-alpha.pdf`, sophgo-doc) это register map codec на стр. 88-91
- `02_Schematic/LicheeRV_Nano-70418_Schematic.pdf` из архива Sipeed это schematic с распиновкой AUD_AINL_MIC, AUD_AOUTR
- `07_Datasheet/Onboard_Components/` из архива Sipeed это datasheets микрофона LMA2718T421 и усилителя AW8010A
- Vendor SDK: `linux_5.10/sound/soc/cvitek/` из sipeed/LicheeRV-Nano-Build (источник vendor-драйверов при backport)
