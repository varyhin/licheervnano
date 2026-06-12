# RTC (sophgo,cv1800b-rtc)

Статус подтверждён на железе WE 2026-06-08 и E 2026-06-12. Базовый RTC работает (`/dev/rtc0`, чтение/запись времени, ход счётчика). Темп хода без калибровки осциллятора неверен (60-75% реальной скорости, замер E 2026-06-12), исправлено калибровкой в `patches/linux/0022`, после неё 60±1 с за минуту. Alarm-wakeup на mainline-драйвере не срабатывает (ограничение, см. ниже).

## Что это

Внутренний RTC SoC CV1800B/SG2002 в домене RTCSYS (32 кГц осциллятор, Power-on-Reset, стейт-машина power-on/off/reset, 8051 SRAM). Узел `rtc@5025000` уже есть в mainline `cv180x.dtsi` и enabled, во все варианты приходит через `sg2002.dtsi`. Драйверы тоже в mainline. Гэп был только в kernel-config.

## Конфигурация

Включено в `Makefile`, target `kernel`, блок `scripts/config`:

```
--module SOPHGO_CV1800_RTCSYS --module RTC_DRV_CV1800
```

Зависимости были включены ранее: `RTC_CLASS=y`, `RTC_HCTOSYS=y` (`HCTOSYS_DEVICE="rtc0"`), `MFD_CORE`, `MFD_SYSCON`, `REGMAP_MMIO`, `ARCH_SOPHGO`. Смена kernel-config меняет ABI, поэтому собирать только полным `make image` (он пересобирает ядро и out-of-tree модули aic8800/soph_tpu под новое ABI).

Калибровка 32K-осциллятора это `patches/linux/0022-rtc-cv1800-32k-osc-calibration.patch` (порт vendor-алгоритма в probe `rtc-cv1800.c`, kernel-config не меняет).

## Привязка (двухуровневая)

- `SOPHGO_CV1800_RTCSYS` (`drivers/soc/sophgo/cv1800-rtcsys.c`, модуль `cv1800_rtcsys`) это MFD. Матчится по OF-compatible `sophgo,cv1800b-rtc` на узел `rtc@5025000`, создаёт MFD-cell `cv1800b-rtc` и пробрасывает в него IRQ alarm.
- `RTC_DRV_CV1800` (`drivers/rtc/rtc-cv1800.c`, модуль `rtc_cv1800`) это сам RTC. Поднимается по platform-id `cv1800b-rtc` с MFD-cell, regmap и clock `rtc` берёт у parent-syscon.

Жёсткой symbol-зависимости между модулями нет, оба грузятся автоматически по modalias (MFD по `of:`, RTC по `platform:cv1800b-rtc` когда MFD создаёт дочернее устройство). На железе оба в `lsmod` без ручного modprobe.

## Проверка на железе

`hwclock`/`rtcwake` это пакет `util-linux-extra` (в Debian trixie вынесены из базового `util-linux`), он в `EXTRA_PKGS`, в образе предустановлен. Фолбэк при отсутствии это `busybox hwclock`.

```sh
# модули и узел
lsmod | grep -E 'cv1800_rtcsys|rtc_cv1800'
dmesg | grep -i rtc                 # 'registered as rtc0'
ls -l /dev/rtc0
cat /sys/class/rtc/rtc0/name        # sophgo-cv1800-rtc cv1800b-rtc.0.auto

# калибровка осциллятора прошла (patches/linux/0022)
dmesg | grep calibrated             # '32k osc calibrated to NNNNN.NN Hz'
busybox devmem 0x05026000           # ANA_CALIB, не дефолт 0x80030100
busybox devmem 0x05026004           # SEC_PULSE_GEN, низкие 24 бита = частота в 16.8

# чтение/запись (с NTP off, иначе timesyncd мешает, см. ниже)
timedatectl set-ntp false
systemctl stop systemd-timesyncd
hwclock --set --date '2030-01-02 03:04:05' --utc --rtc /dev/rtc0
hwclock -r --utc --rtc /dev/rtc0    # ~2030-01-02 03:04:xx, при повторном чтении +Nс

# темп хода (с NTP off): за минуту RTC должен пройти 60±1 с
hwclock -w
hwclock -r; sleep 60; hwclock -r; date -u
```

## Известные ограничения

- set_time и read_time исправны (замер 2026-06-08 на WE: записали 2030, прочитали 2030). Формулировка того замера про «реальный темп» была неточной, темп тогда не хронометрировался.
- Темп хода и калибровка. Секунды генерируются делителем SEC_PULSE_GEN из внутреннего 32K RC-осциллятора (QFN-корпус, FSBL печатает «Use internal 32k»). Без калибровки делитель стоит в заводском дефолте 32768.0 при реальной частоте RC около 21-24 кГц, поэтому RTC шёл на 60-75% реальной скорости и плыл от температуры (замеры на E 2026-06-12 без патча: темп 0.64 за 60 с и 0.71 за 10 с). `patches/linux/0022` портирует vendor-калибровку (osdrv/interdrv/v2/rtc) в probe драйвера. Коарс-стадия двоичным поиском подгоняет аналоговый трим ANA_CALIB до 755-770 тактов опорных 25 МГц на период 32K, файн-стадия меряет 256 периодов и пишет фактическую частоту в SEC_PULSE_GEN в фиксированной точке 16.8. Подтверждено на E 2026-06-12: dmesg «32k osc calibrated to 32595.18 Hz», ANA_CALIB сменился с 0x80030100 на 0x10198, SEC_PULSE_GEN с 0x00800000 на 0x007F5330, замер дал 61.0 с RTC за ~61 с стенного времени. Калибровка выполняется на каждом probe (boot или reload модуля) и только в режиме внутреннего осциллятора (бит 10 rtc_ctrl0 равен 0).
- Конфаунд NTP. На вариантах с сетью `systemd-timesyncd` владеет RTC, пишет в него системное время по NTP и откатывает ручной `date -s`. Из-за этого ручной `hwclock -w` без `set-ntp false` выглядит как «запись не легла» (timesyncd возвращает системные часы раньше, чем hwclock их прочитает). Именно timesyncd делает первый `set_time` после boot, поэтому RTC оказывается enabled, хотя ранний `hctosys` падает с `unable to read the hardware clock` (на момент загрузки модуля RTC ещё не enabled, это норма, не ошибка).
- Alarm-wakeup НЕ работает. `echo +N > /sys/class/rtc/rtc0/wakealarm` принимается (узел читает текущее время и взводит alarm), но при достижении счётчиком момента alarm IRQ `rtc alarm` не инкрементируется и `wakealarm` не сбрасывается (чистый замер с NTP off 2026-06-08). Это поведение mainline-драйвера на этом железе, кандидат на будущий патч драйвера. На включение RTC и таймкипинг не влияет.
- Персист времени. Счётчик в домене VDDBKUP идёт от осциллятора и переживает warm-reboot. ПОДТВЕРЖДЕНО на железе 2026-06-09: с NTP off записали `2035-03-03 03:03:03`, `reboot`, после загрузки `hwclock -r` = `2035-03-03 03:04:06` (значение сохранилось + счётчик прошёл ~63с даунтайма, `NTP=no` через reboot). Полный power-off без батарейки VBAT (на плате вряд ли распаяна) время теряет.
