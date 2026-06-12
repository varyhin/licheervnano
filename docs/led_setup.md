# USER LED на LicheeRV Nano (GPIOA14)

Управляемый светодиод платы и его настройка. Итог проверок на железе
2026-06-03/04.

## Что на плате

- Синий LED у кнопки `USER` это user-LED `D1`, схемный узел
  `GPIOA_14 -> LED1 -> R28 5.1K -> GND`. Это ЕДИНСТВЕННЫЙ управляемый LED.
  Полярность `GPIO_ACTIVE_HIGH` (пин HIGH = горит). Распаян (прежняя гипотеза
  про DNP опровергнута замером).
- Красный LED у кнопки `RESET` это `LED2`, аппаратный индикатор питания 3.3V
  (`VDD3V3_SYS -> LED2 -> R30 5.1K -> GND`), к GPIO НЕ подключён, софтом не
  управляется. Отключить только выпайкой `R30`/`LED2`. На GPIOA14 не реагирует.

## Две вещи, без которых синий не работает

1. Полярность. В DTS узел `gpio-leds`/`user-led` должен быть
   `<&porta 14 GPIO_ACTIVE_HIGH>` (как в upstream/vendor). Прежний патч
   `0006` ставил `ACTIVE_LOW` это инвертировало LED (в покое горел), удалён.
2. Пинмукс пада. `GPIOA14` это пад `SD0_PWR_EN`. Reset/boot оставляет его в
   функции `SD0_PWR_EN` (fmux `0x03001038` = `0x0`), которая держит пад HIGH,
   поэтому `gpio-leds` пишет в регистр вывода, но до пада это не доходит и синий
   горит всегда. Нужно перевести пад в GPIO (fmux = `0x3`).

Замер, подтвердивший диагноз (на железе): при fmux `0x0` `gpio-leds` гоняет
`DR14` 0/1, но `EXT14` залип в `1` (пад под SD0_PWR_EN). После `fmux=0x3`
`EXT14` следует за `DR14`, синий мигает в такт.

## Как ставится пинмукс это DTS pinctrl

`SD0_PWR_EN` это именованный пин mainline (`PIN_SD0_PWR_EN` в
`pinctrl-sg2002`), поэтому в отличие от I2C1/UART (там runtime-devmem, см.
`docs/i2c_setup.md`) пинмукс задаётся в board-DTS:

```
&pinctrl {
	user_led_cfg: user-led-cfg {
		user-led-pins {
			pinmux = <PINMUX(PIN_SD0_PWR_EN, 3)>;  /* 3 = GPIO */
			bias-disable;
			power-source = <3300>;
		};
	};
};

&{/leds} {
	pinctrl-names = "default";
	pinctrl-0 = <&user_led_cfg>;
};
```

Ядро применяет `default`-стейт при probe `leds-gpio`, переводя пад в GPIO без
зависимости от boot. Тот же патч `patches/linux/0018-...-user-led.patch`
(покрывает b/e/w/we) ещё и выключает LED по умолчанию (`default-state = "off"`
вместо `linux,default-trigger = "mmc0"`, в покое погашен) и переименовывает
sysfs-лейбл `licheerv-nano:green:user` -> `licheerv-nano:blue:user` (LED синий).

## Поведение при загрузке (boot)

Синий гасится максимально рано, в FSBL. Без этого пад `SD0_PWR_EN` по умолчанию
держит линию HIGH, и синий горел бы весь boot (MaskROM → FSBL → OpenSBI →
U-Boot → ранний Linux) до момента, когда ядро прогонит leds-gpio. Поэтому в
`bl2_main()` (после `load_ddr()`, до `load_rest()`) добавлен мукс `GPIOA14 → GPIO`
(`PINMUX_BASE+0x38 = 0x3`) + drive LOW по `GPIO0 0x03020000`. FSBL это M-mode,
прямой MMIO доступен (в mainline U-Boot S-mode тот же приём виснет, узел не
замаплен в DT, потому делаем именно в FSBL). OpenSBI и U-Boot `GPIOA14` не трогают, LOW сохраняется до Linux.
Патч `patches/fsbl/0002-user-led-off-blue.patch`.

Красный (`LED2`) погасить на boot НЕЛЬЗЯ ни на одном уровне: он не подключён к
GPIO (индикатор рельса 3.3V), горит всё время при наличии питания. Только выпайка.

## Управление через sysfs

```
LED=/sys/class/leds/licheerv-nano:blue:user
cat $LED/trigger              # доступные режимы, в [скобках] текущий

# ручной on/off
echo none > $LED/trigger
echo 1 > $LED/brightness      # горит (после фикса пинмукса+полярности)
echo 0 > $LED/brightness      # гаснет

# по умолчанию LED выключен (default-state=off, без триггера); режим ставится вручную:
echo mmc0 > $LED/trigger       # вспышка при доступе к SD
```

## Режимы (триггеры)

Доступно в образе: `none`(дефолт, LED off), `mmc0`/`mmc1`, `heartbeat`(+`invert`),
`default-on`, `disk-activity`/`disk-read`/`disk-write`, `kbd-*`, плюс `netdev`
и `panic` (добавлены через kernel-config). Примеры по каждому режиму в
`docs/gpio_setup.md` (раздел USER LED).

- `netdev`: `echo netdev > $LED/trigger; echo eth0 > $LED/device_name;
  echo 1 > $LED/link; echo 1 > $LED/tx; echo 1 > $LED/rx` (на W/WE `wlan0`).
- `panic`: LED при kernel panic. Один LED, триггеры взаимоисключающие; для
  panic поверх обычного режима есть DT-свойство `panic-indicator`.

## Диагностика регистрами (дёшево, без перепрошивки)

`busybox devmem` или python+mmap по `/dev/mem`. База GPIOA `0x03020000`:
DR `+0x00`, DIR `+0x04`, EXT_PORTA `+0x50` (бит14). Пинмукс пада `0x03001038`
(`0x3`=GPIO, `0x0`=SD0_PWR_EN). Важно: `dd` по `/dev/mem` на этом ядре отдаёт
нули, нужен mmap (или `busybox devmem`, не standalone `devmem`).

## Связанные

- `docs/gpio_setup.md` (USER LED через sysfs + все режимы с примерами)
- `docs/sg2002_pin_map.md` (GPIOA14 = SD0_PWR_EN)
- `docs/i2c_setup.md`, `docs/uart_setup.md` (runtime-devmux паттерн для пинов
  без mainline-имени; для LED не нужен, пин именованный)
