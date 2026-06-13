# Watchdog (snps,dw-wdt)

Статус подтверждён на железе WE 2026-06-09. DesignWare APB watchdog работает полностью (probe, identity, кормление, укус/reset по таймауту).

## Что это

DesignWare APB watchdog SoC CV1800B/SG2002 по адресу 0x3010000. Mainline-драйвер `drivers/watchdog/dw_wdt.c` (compatible `snps,dw-wdt`) уже есть. Гэп был двойной: нет узла в mainline dtsi И выключен `CONFIG_DW_WATCHDOG` (хотя `WATCHDOG_CORE=y` был).

## Конфигурация

- DTS-узел добавлен патчем `patches/linux/0019-licheerv-nano-watchdog.patch` в `cv180x.dtsi` (SoC-уровень, покрывает все 4 варианта B/E/W/WE через `sg2002.dtsi`).
- В `Makefile` (target `kernel`) добавлено `--module DW_WATCHDOG`.

Узел целиком на mainline-ссылках, побайтно сверен с vendor `cv-wd@0x3010000` (vendor DT из SDK Sipeed):

```
watchdog@3010000 {
	compatible = "snps,dw-wdt";
	reg = <0x3010000 0x1000>;
	clocks = <&clk CLK_APB_WDT>;
	clock-names = "tclk";
	resets = <&rst RST_WDT>;
	interrupts = <SOC_PERIPHERAL_IRQ(42) IRQ_TYPE_LEVEL_HIGH>;
};
```

reg `0x3010000/0x1000`, reset `RST_WDT`=48 (=vendor `0x30`), IRQ `SOC_PERIPHERAL_IRQ(42)`=58 (=vendor `cv181x_base_riscv.dtsi` `cv-wd@0x3010000 interrupts=<58 LEVEL_HIGH>`; макрос `(nr)+16` определён в mainline `sg2002.dtsi`), clock `CLK_APB_WDT`=58 (tclk, единственный WDT-клок в mainline). Модуль `dw_wdt` грузится по modalias `of:...snps,dw-wdt` без ручного modprobe.

## Проверка на железе

`wdctl` это util-linux. Любое write в `/dev/watchdog0` кроме `V` это keepalive-ping; `V` это magic-close (корректная остановка, `NOWAYOUT` выключен).

Фаза A. Инфо (недеструктивно):

```sh
lsmod | grep dw_wdt
dmesg | grep -iE 'dw_wdt|watchdog'
ls -l /dev/watchdog0
wdctl /dev/watchdog0           # identity, timeout
```

Фаза B. Keepalive (недеструктивно, кормить дольше таймаута):

```sh
( exec 3>/dev/watchdog0
  for i in $(seq 1 50); do printf w >&3; sleep 1; done   # 50с > 42с дефолта
  printf V >&3 )                                          # стоп
```

Плата должна прожить все 50с (кормление сбрасывает счётчик).

Фаза C. Укус (ДЕСТРУКТИВНО, плата перезагрузится):

```sh
wdctl -s 10 /dev/watchdog0     # опц. короче таймаут
exec 3>/dev/watchdog0          # взвести и НЕ кормить, НЕ закрывать 'V'
# ждать > таймаута -> WDT кусает -> reset -> reboot
```

После ребута `uptime` покажет свежий boot (на железе 2026-06-09: взвели 08:51:34 с таймаутом 10с, через ~10с connection abort = reset, после реконнекта `up 1 min`).

## Известные ограничения

- Дефолтный таймаут 42с. `SETTIMEOUT` работает (`wdctl -s 10` выставил 10с и укус сработал на 10с), несмотря на сообщение про TOPs ниже.
- `dw_wdt 3010000.watchdog: No valid TOPs array specified` в dmesg это информационное, не ошибка. Мы (как и vendor) не задаём опциональный `snps,watchdog-tops`, драйвер берёт дефолтные TOP. Таймаут считается корректно (клок прочитан), set/get/укус работают.
- `CONFIG_WATCHDOG_SYSFS=y` включён, sysfs-атрибуты `/sys/class/watchdog/watchdog0/{identity,timeout,state}` доступны (подтверждено на железе 2026-06-09: identity `Synopsys DesignWare Watchdog`, timeout 42, state inactive). Даёт инспекцию без удержания устройства открытым; `wdctl` (ioctl) тоже работает.
- `interrupts` в узле это pretimeout-линия (опциональна в драйвере). Базовый reset-по-таймауту IRQ не требует.
