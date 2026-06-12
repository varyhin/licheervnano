# RTC (sophgo,cv1800b-rtc)

Статус подтверждён на железе WE 2026-06-08. Базовый RTC работает (`/dev/rtc0`, чтение/запись времени, ход счётчика). Alarm-wakeup на mainline-драйвере не срабатывает (ограничение, см. ниже).

## Что это

Внутренний RTC SoC CV1800B/SG2002 в домене RTCSYS (32 кГц осциллятор, Power-on-Reset, стейт-машина power-on/off/reset, 8051 SRAM). Узел `rtc@5025000` уже есть в mainline `cv180x.dtsi` и enabled, во все варианты приходит через `sg2002.dtsi`. Драйверы тоже в mainline. Гэп был только в kernel-config.

## Конфигурация

Включено в `Makefile`, target `kernel`, блок `scripts/config`:

```
--module SOPHGO_CV1800_RTCSYS --module RTC_DRV_CV1800
```

Зависимости были включены ранее: `RTC_CLASS=y`, `RTC_HCTOSYS=y` (`HCTOSYS_DEVICE="rtc0"`), `MFD_CORE`, `MFD_SYSCON`, `REGMAP_MMIO`, `ARCH_SOPHGO`. Смена kernel-config меняет ABI, поэтому собирать только полным `make image` (он пересобирает ядро и out-of-tree модули aic8800/soph_tpu под новое ABI).

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

# чтение/запись (с NTP off, иначе timesyncd мешает, см. ниже)
timedatectl set-ntp false
systemctl stop systemd-timesyncd
hwclock --set --date '2030-01-02 03:04:05' --utc --rtc /dev/rtc0
hwclock -r --utc --rtc /dev/rtc0    # ~2030-01-02 03:04:xx, при повторном чтении +Nс
```

## Поведение и ограничения

- set_time и read_time исправны (замер 2026-06-08: записали 2030, прочитали 2030, счётчик идёт в реальном темпе).
- Конфаунд NTP. На вариантах с сетью `systemd-timesyncd` владеет RTC, пишет в него системное время по NTP и откатывает ручной `date -s`. Из-за этого ручной `hwclock -w` без `set-ntp false` выглядит как «запись не легла» (timesyncd возвращает системные часы раньше, чем hwclock их прочитает). Именно timesyncd делает первый `set_time` после boot, поэтому RTC оказывается enabled, хотя ранний `hctosys` падает с `unable to read the hardware clock` (на момент загрузки модуля RTC ещё не enabled, это норма, не ошибка).
- Alarm-wakeup НЕ работает. `echo +N > /sys/class/rtc/rtc0/wakealarm` принимается (узел читает текущее время и взводит alarm), но при достижении счётчиком момента alarm IRQ `rtc alarm` не инкрементируется и `wakealarm` не сбрасывается (чистый замер с NTP off 2026-06-08). Это поведение mainline-драйвера на этом железе, кандидат на будущий патч драйвера. На включение RTC и таймкипинг не влияет.
- Персист времени. Счётчик в домене VDDBKUP идёт от осциллятора и переживает warm-reboot. ПОДТВЕРЖДЕНО на железе 2026-06-09: с NTP off записали `2035-03-03 03:03:03`, `reboot`, после загрузки `hwclock -r` = `2035-03-03 03:04:06` (значение сохранилось + счётчик прошёл ~63с даунтайма, `NTP=no` через reboot). Полный power-off без батарейки VBAT (на плате вряд ли распаяна) время теряет.
