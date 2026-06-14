# Thermal sensor (TEMPSEN)

Статус подтверждён на железе WE 2026-06-09. Встроенный датчик температуры SoC работает: модуль грузится по modalias, thermal-zone отдаёт реальную температуру, точки срабатывания на месте, под нагрузкой температура растёт.

## Что это

Встроенный в SoC CV1800B/SG2002 датчик температуры (TEMPSEN) по адресу `0x030E0000`. В mainline на момент нашего freeze v6.18.29 не было ни узла в dtsi, ни драйвера в `drivers/thermal/`.

Подход выбран mainline-newer (готовый неслитый upstream-драйвер вместо форка vendor). Существует upstream-сабмишн «thermal: cv1800: Add cv1800 thermal driver support» (Haylen Chu, серия v5 от 2024-10-14, `lore.kernel.org/linux-pm/20241014073813.23984-3-heylenay@4d2.org`), который в mainline так и не приземлился. Драйвер `drivers/thermal/cv1800_thermal.c` (296 строк, self-contained, только clk + IRQ + thermal-framework, без reset) взят из этой серии дословно. Это в разы чище vendor-драйвера `cvitek,cv181x-thermal`, исходника которого у нас нет (встроен в vendor-ядро 5.10).

## Конфигурация

- DTS-узлы добавлены патчем `patches/linux/0020-licheerv-nano-thermal.patch` в `cv180x.dtsi` (SoC-уровень, покрывает все 4 варианта B/E/W/WE через `sg2002.dtsi`). Тот же патч создаёт `drivers/thermal/cv1800_thermal.c` + `Kconfig` (`CV1800_THERMAL`) + `Makefile`.
- В `Makefile` (target `kernel`) добавлено `--module CV1800_THERMAL`. `CONFIG_THERMAL=y` и `CONFIG_THERMAL_OF=y` уже были включены defconfig, гэп был только в `CV1800_THERMAL`.

Узел сенсора целиком на mainline-ссылках:

```
soc_temp: thermal-sensor@30e0000 {
	compatible = "sophgo,cv1800-thermal";
	reg = <0x30e0000 0x100>;
	clocks = <&clk CLK_TEMPSEN>;
	interrupts = <SOC_PERIPHERAL_IRQ(0) IRQ_TYPE_LEVEL_HIGH>;
	#thermal-sensor-cells = <0>;
};
```

reg `0x30e0000/0x100`, clock `CLK_TEMPSEN`=17 (`sophgo,cv1800.h`, гейт `clk_tempsen` уже реализован в `clk-cv1800.c`, родитель osc). IRQ: vendor `cv181x_base_riscv.dtsi` даёт `thermal@030E0000 interrupts=<16 LEVEL_HIGH>`, а макрос `SOC_PERIPHERAL_IRQ(nr)=(nr)+16` определён в mainline `sg2002.dtsi`, поэтому raw 16 = `SOC_PERIPHERAL_IRQ(0)` (vendor пишет raw, mainline через макрос). В финальном dtb узел = `interrupts=<0x10 0x04>` (точно как vendor). Модуль `cv1800_thermal` грузится по modalias `of:...sophgo,cv1800-thermal` без ручного modprobe.

Reset не используется: vendor-узел упоминал `reset-names "tempsen"`, но upstream-драйвер обходится без него.

## Thermal-zone и точки срабатывания

```
thermal-zones {
	soc-thermal {
		polling-delay-passive = <1000>;
		polling-delay = <1000>;
		thermal-sensors = <&soc_temp>;
		trips {
			soc-passive  { temperature = <85000>;  hysteresis = <5000>; type = "passive";  };
			soc-hot      { temperature = <95000>;  hysteresis = <5000>; type = "hot";       };
			soc-critical { temperature = <110000>; hysteresis = <0>;    type = "critical";  };
		};
	};
};
```

Важно: cooling-устройства у нас нет (нет cpufreq/devfreq/TPU cooling-map). `passive` инертен потому, что governor'у нечем управлять без cooling-устройства. `hot` инертен потому, что драйвер регистрирует только `.get_temp` и `.set_trips`, а `.hot`-callback не задан, поэтому вызов ядра `handle_critical_trips()` к `tz->ops.hot` это no-op. Функционально срабатывает только `critical`: при пересечении ядро уходит в аварийное hw_protection-выключение (emergency shutdown, `thermal_zone_device_halt` → `__hw_protection_trigger`; действие конфигурируемо, по умолчанию poweroff). 110°C выбран с запасом под TPU/разгон и ниже Tj max кремния ~125°C, чтобы не ложно-срабатывать. Автоматического троттлинга нет, это отдельная задача (привязать thermal к cpufreq/devfreq cooling).

## Проверка на железе

Динамик и нагрузочные модули не нужны.

Фаза A. Инфо (недеструктивно):

```sh
lsmod | grep cv1800_thermal                      # модуль загружен
dmesg | grep -i cv1800_thermal                   # пусто = чистый probe (драйвер молчит при успехе)
cat /sys/class/thermal/thermal_zone0/type        # soc-thermal
cat /sys/class/thermal/thermal_zone0/temp        # millicelsius, напр. 37802 = 37.8C
grep . /sys/class/thermal/thermal_zone0/trip_point_*_{temp,type}
# 0 -> 85000/passive, 1 -> 95000/hot, 2 -> 110000/critical
```

Фаза B. Рост под нагрузкой (недеструктивно):

```sh
cat /sys/class/thermal/thermal_zone0/temp                # baseline
for i in $(seq $(nproc)); do yes >/dev/null & done       # загрузить все ядра
watch -n1 cat /sys/class/thermal/thermal_zone0/temp      # температура растёт
kill %1 %2 %3 %4 ; wait 2>/dev/null                       # снять нагрузку (или kill -9 PID)
```

На железе 2026-06-09 (вариант WE): idle `37802` mC (37.8°C, разумно для пассивного охлаждения), под нагрузкой `yes` на всех ядрах температура поднималась, после снятия нагрузки падала.

## Известные ограничения

- Формула raw->температура (из драйвера): `temp(mC) = result*1000*716/2048 - 273000`, где divider 2048 это число тактов накопления (`TEMPSEN_SET_ACCSEL_2048T`). Сырой результат в регистре `RESULT(0)` (`base+0x20`, биты [12:0]); для idle 37.8°C raw ≈ 889.
- Драйвер при успешном probe ничего не печатает (только `dev_err_probe` при ошибке), поэтому пустой `dmesg | grep` это норма.
- `critical` trip деструктивен: при 110°C ядро инициирует аварийное hw_protection-выключение (emergency shutdown). На пассивно охлаждаемой плате при штатной работе (включая TPU на 700 МГц) до этого далеко.
- `set_trips` в драйвере программирует аппаратные пороги прерывания, так что зона событийная (не только polling); `polling-delay` 1000 мс это страховочный опрос.
