# Reboot и poweroff на LicheeRV Nano (SG2002)

Как работает программная перезагрузка на mainline-стеке и что понадобилось, чтобы она заработала.

Статус подтверждён на железе 2026-07-04. Механизм сброса (фикс A) общий для всех вариантов B/E/W/WE. Возврат Wi-Fi после reboot (фикс B) проверен на W, несколько reboot подряд и переключение B→nano-w.

## Что было сломано

Mainline OpenSBI под этот SoC не имеет reset-device, поэтому SBI SRST это no-op. Linux `reboot` уходил в SBI SRST (restart-handler приоритета 192), OpenSBI возвращал `SBI_ENOTSUPP`, аппаратного сброса не происходило, и плата просто halt-илась. Оживало только снятием питания. Это касалось всех вариантов, на B/E просто нет Wi-Fi, чтобы заметить по SSH.

Отдельно watchdog-fallback ядра (`dw_wdt`, приоритет 128) сам по себе не спасал: голый сброс DesignWare-watchdog на этом SoC частичный, и плата зависала в раннем бутлоадере, не поднимаясь.

## Фикс A: reset-device в OpenSBI через домен RTCSYS

Ключ в том, что полный восстанавливаемый сброс чипа делается через домен RTCSYS. Чтобы сброс DW-watchdog превратился в полный сброс, надо предварительно включить маршрутизацию в RTCSYS. Это повторяет вендорскую последовательность FSBL `__system_reset`.

- `patches/opensbi/0001-cv1800b-rtcsys-sysreset.patch` добавляет `fdt_reset`-драйвер `fdt_reset_cv1800b.c` (`sbi_system_reset_device`, compatible `sophgo,cv1800b-sysreset`). На SBI SRST он:
  - включает маршрутизацию RTCSYS: `0x050260E0=1`, `0x050260C8=1`, `0x050250AC=0`, unlock `0x05025004=0xAB18`, `0x05025008=0x00400040` (бит 6);
  - на reboot взводит DW-watchdog `0x03010000` (TORR `0x66`, CRR `0x76`, CR `0x11`) и спинит, укус даёт полный сброс;
  - на shutdown идёт по ветке `EN_SHDN_REQ` (`0x050260C0`), поэтому чинится и `poweroff`.
- `patches/uboot/0004-licheerv_nano-cv1800b-sysreset-node.patch` добавляет узел `sophgo,cv1800b-sysreset` в контрольный DTS `sg2002-licheerv-nano-b.dts`. Он попадает в `u-boot.dtb`, который OpenSBI видит через `FW_FDT_PATH` (в `firmware/fw_base.S` при заданном `FW_FDT_PATH` a1 переопределяется на встроенный `fw_fdt_bin`). Бонус: привязывается штатный `CONFIG_SYSRESET_CV1800B`, и `reset` заработал в самом U-Boot.
- В `Makefile` заведена категория `patches/opensbi/` (apply/check/revert).

Признак работы на плате это строка `SBI SRST extension detected` в раннем dmesg (без reset-device SRST не анонсируется).

## Фикс B: возврат Wi-Fi после reboot (только W/WE)

Сам reboot после фикса A поднимает плату на всех вариантах. Но на W/WE радио AIC8801 сидит на отдельной рельсе (GPIOA26, active-low) и не сбрасывается сбросом SoC, поэтому после reboot чип залипал (`mmc1: Failed to initialize`). Лечит `patches/fsbl/0003-aic8800-power-off-drain.patch`: FSBL рано уводит GPIOA26 в LOW, чип обесточен весь остаток загрузки и осушается, а Linux `mmc-pwrseq` поднимает питание при инициализации mmc1. Осушение перекрывается обычной загрузкой, поэтому задержки нет. На B/E GPIOA26 это неиспользуемый пад EMMC_DAT2, безвредно. Подробности в `docs/wifi_setup.md`.

## Проверка на железе

```sh
dmesg | grep -i 'SBI SRST'        # SBI SRST extension detected -> reset-device активен
reboot now                         # плата уходит в сброс и поднимается сама (все варианты)
# на W/WE после загрузки:
ip -br link show wlan0             # wlan0 UP без снятия питания
dmesg | grep -iE 'mmc1|aic'        # mmc1: new SDIO card, без Failed to initialize
```

## Связанные документы

- `docs/wifi_setup.md` это возврат Wi-Fi после reboot на W/WE (фикс B)
- `docs/watchdog_setup.md` это DW-watchdog как источник сброса
