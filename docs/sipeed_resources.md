# Официальные ресурсы Sipeed для LicheeRV Nano

Сводка downloads из официального файлохранилища Sipeed и анализ
schematic для нашего mainline bring-up.

## Источник

`https://cn.dl.sipeed.com/shareURL/LICHEE/LicheeRV_Nano`

Веб-интерфейс к публичному файлохранилищу. API:
`POST https://api.dl.sipeed.com/fileList/LICHEE/LicheeRV_Nano`
возвращает JSON со списком файлов. Download:
`https://api.dl.sipeed.com/file/download?file_url=<path>`. Большинство
PDF доступны без verify_code, datasheet'ы onboard-компонентов
закрыты CAPTCHA.

### GitHub-репозитории Sipeed

- `https://github.com/orgs/sipeed` это GitHub-организация Sipeed, все публичные репозитории вендора (платы, SDK, инструменты).
- `https://github.com/sipeed/LicheeRV-Nano-Build` это официальный сборочный SDK платы (osdrv + linux_5.10 + buildroot). Наш зафиксированный пин SHA лежит в `manifest/sources.mk` (`licheerv-nano-build-vendor`), снапшот используется как источник vendor-драйверов и init-последовательностей при mainline bring-up.

## Состав файлохранилища

8 каталогов:

| Каталог | Содержимое |
|---|---|
| 01_Specification | LicheeRV_Nano_v70405_specification_V1.0_en.pdf (645 KB) |
| 02_Schematic | 3 schematic PDF (70405, 70415, 70418) + LicheeRV Claw (490 KB - 781 KB) |
| 03_Designator_drawing | LicheeRV_Nano-70405_iBOM.rar (1.24 MB) |
| 04_Mechanical_drawing | LicheeRV_Nano_70405_Dimension.7z (208 KB) |
| 05_PCB_Lib | (не загружено) |
| 06_3D_file | (не загружено) |
| 07_Datasheet | SG2002_TRM_V1.0-alpha.pdf (18.5 MB), SG2002_Datasheet_V1.0-alpha (8.1 MB), Onboard_Components/ |
| 08_RVClaw | (отдельный продукт) |

## Mapping PCB ревизий на наши DTS варианты

| Sipeed PCB | Наш DTS | Wi-Fi+BT | Ethernet | LCD/Backlight | Camera |
|---|---|---|---|---|---|
| 70405 | W (без E) | AIC8800D | нет | AW9962E driver | 4 lane MIPI |
| 70415 | W (различная разводка камеры?) | AIC8800D | нет | AW9962E driver | 4 lane MIPI |
| 70418 | WE | AIC8800D | 10/100M PHY | AW9962E driver | 4 lane MIPI |
| (нет schematic) | E (Ethernet) | нет (возможно DNP AIC8800D на 70418) | 10/100M PHY | AW9962E driver | 4 lane MIPI |
| (нет schematic) | B (basic) | возможно DNP placement AIC8800D на 70405? | нет | возможно DNP |  |

Из 3 опубликованных schematic'ов B (basic, без Wi-Fi/BT/Ethernet) не
найден отдельно. Возможно Sipeed продаёт B-вариант как 70405 ревизию
PCB с не запаянным AIC8800D (DNP), либо B имеет внутренний неопубликованный
SCH. E (Ethernet без Wi-Fi) тоже не имеет отдельного schematic, вероятно
это 70418 (WE) с не запаянным AIC8800D. Программно у нас 4 DTS варианта
(B/E/W/WE), что покрывает hardware конфигурации с/без Ethernet и с/без Wi-Fi.

## Ключевые находки из schematic (актуально для текущего bring-up)

### USER LED это ACTIVE_HIGH на GPIOA14 (управляемый D1)

По прямому замеру на железе 2026-06-03 синий LED у кнопки USER это
user-LED `D1` на `GPIOA14`, РАСПАЯН, полярность `GPIO_ACTIVE_HIGH`
(пин HIGH = горит), по умолчанию off (label `licheerv-nano:blue:user`).
Красный у кнопки RESET это `LED2`, индикатор питания 3.3V (НЕ 5V VBUS),
к GPIO не подключён, софтом не управляется. По тексту схемы:
`GPIOA_14 → LED1 → R28 5.1K → GND` (active-high), `VDD3V3_SYS → LED2 →
R30 5.1K → GND` (индикатор). Vendor подтверждает:
`src/licheerv-nano-build-vendor/build/boards/sg200x/sg2002_licheervnano_sd/u-boot/cvi_board_init.c`
(`user_led_on()` = пин HIGH) + board-DTS `GPIO_ACTIVE_HIGH`. Верную
полярность задаёт `patches/linux/0018-licheerv-nano-user-led.patch`
(b/e/w/we), раннее гашение синего в boot это
`patches/fsbl/0002-user-led-off-blue.patch`.

Исторические заблуждения (схемный разбор active-low, версия «D1 DNP на
70418», теория «оба LED у USB-C это индикаторы питания» с привязкой
цветов к шинам) опровергнуты замером 2026-06-03 и удалены из этого
документа. Корнем ошибки была инверсия от прежнего патча `0006`
(active-low, LED горел в покое), патч удалён (коммит bc0f2cdbe).
Актуальный разбор в `docs/led_setup.md` и `docs/gpio_setup.md`.

### USER button (gpio-keys на porta 30)

Наш патч 0001 добавляет gpio-keys поверх mainline DTS Thomas Bonnefille (в самом mainline этого узла нет):

```
user-button {
    label = "user";
    linux,code = <KEY_DISPLAYTOGGLE>;
    debounce-interval = <10>;
    gpios = <&porta 30 GPIO_ACTIVE_LOW>;
};
```

На железе кнопка USER работает (вариант E, проверено evtest 2026-06-13):
нажатие даёт событие `KEY_DISPLAYTOGGLE` (code 431) на `/dev/input/event0`,
value 1 на нажатие и value 0 на отпускание. Узел gpio-keys рабочий, GPIO 30
подключён к физической кнопке, не фантом.

- USER = gpio-keys на `&porta 30`, `KEY_DISPLAYTOGGLE`, читается Linux
- RESET = аппаратный сброс через SYS_RSTN, в Linux как клавиша не приходит

Прежняя запись в этом файле утверждала, что USER-кнопки на pcb нет (вывод
из схематического блока "PWR & User LED | BOOT & RESET KEY" без проверки на
железе). Замер evtest это опроверг. Вики Sipeed перечисляет только RST+BOOT
и не упоминает USER, поэтому раскладку кнопок стоит сверять по железу.

### LED2 (красный) это индикатор питания 3.3V, всегда горит при наличии питания

ПОПРАВКА (схема 70418 стр.3, перечитано 2026-06-04): прежняя запись «cathode
SYS_RSTN» НЕВЕРНА. По блоку «PWR & User LED | BOOT & RESET KEY» красный `LED2`
разведён `VDD3V3_SYS — LED2 — R30 5.1K — GND`, обе ноги это питание и земля.
`SYS_RSTN` это ОТДЕЛЬНЫЙ узел нижней половины блока (RESET KEY):
`VDD1V8_SYS — R64 10K — SYS_RSTN — SW2 — C63 100nF`, к `LED2` не подключён.
Прежняя версия спутала верхнюю (LED) и нижнюю (кнопки) половины блока.

Следствие: `LED2` горит всегда, пока есть рельс 3.3V, одинаково на всех стадиях
(MaskROM/FSBL/OpenSBI/U-Boot/ОС). Это объясняет «always-on» без всякого
reverse-bias. К GPIO не подключён, к `SYS_RSTN` не подключён, программно не
управляется НИ на одном уровне загрузки. Выключить только физически (выпаять
`R30` или `LED2`). Подтверждено железом: тест изоляции (не реагирует на GPIOA14)
+ наблюдение (горит при загрузке = горит всегда). Актуальный итог:
`docs/led_setup.md`.

### Wi-Fi/BT чип это AIC8800D-44Pin (Fn-Link N240 модуль)

Footprint U13 на схеме SCH блок "Wi-Fi & BT". 44-pin модуль
Fn-Link N240 на базе AIC8800D. Подтверждает что наш `vid:0x5449
did:0x0145` (определённый user'ом) соответствует AIC8801 U03 die в
AIC8800D пакете. "AIC8800D80" это маркетинговое имя, под которым Sipeed
продаёт Wi-Fi этого же модуля (и так же называется его прошивка, см.
NOTICE.md), а не отдельный вариант чипа: физически на платах LicheeRV Nano
70405/70415/70418 стоит этот AIC8800D-44Pin (Fn-Link N240).

R47..R53 это 33K pull-up на SDIO1 D0/D1/D2/D3/CMD/CLK линии между
SoC и AIC8800. WF_PWR_EN (через R53 33K) включает Wi-Fi питание.
HOST_WAKE_WF (через R54 33K) сигнал wake-on-wlan от AIC8800 в SoC.

UART HCI для Bluetooth выведен на 4-pin connector RN1 (NC по
дефолту, требует установки соединительных резисторов): BT_CTS,
BT_RTX, BT_TXD, BT_RXD. Для UART HCI BT нужно мостить эти 4 пина
0R резисторами. В нашем mainline bring-up BT работает через SDIO
(не UART), что не требует переразводки.

### LCD Backlight Driver это AW9962E (не USER LED!)

Footprint U14 "AW9962EDNR" блок "Backlight LED Driver". Принимает
PWM сигнал `BL_PWM` (источник не указан в этой странице) и драйвит
LCD0_BL+ / LCD0_BL- (anode/cathode подсветки LCD панели). C40
10uF/25V boost output capacitor, L4 10uH boost inductor это
DC-DC converter для повышения 3.3V до Vf×N (где N это количество
последовательных LED в backlight).

AW9962E НЕ управляет USER LED. USER LED это обычный gpio-driven
LED. AW9962E это backlight driver чип, активируется только при
подключении LCD модуля.

Для нашего bring-up LCD на header AW9962E пока не используется.
Если будет подключаться LCD, потребуется PWM сигнал на BL_PWM
input и backlight выйдет на FPC1 (page 4 schematic).

### Ethernet PHY это внутренний 10/100M PHY SG2002 + magnetics

70418 page 4, блок "10/100M PHY":

- RJ1: 8-pin RJ45 connector
- U7: 4-pin transformer для TX (PCAQ2012A-801T030 или PSTFAQ3416-600T020
  по datasheet onboard)
- U10: 4-pin transformer для RX (та же модель)
- 4× 100nF caps по AC coupling между PHY pins SoC и transformers

SoC pins:
- EPHY_TXP (pin 65), EPHY_TXM (pin 64) → U8 → connector pairs T_P/T_N
- EPHY_RXP (pin 63), EPHY_RXM (pin 62) → U7 → connector pairs R_P/R_N

Наш patches/linux/0003-cv1800b-ephy-init-driver.patch обеспечивает
init sequence для PHY чтобы он отвечал на MDIO bus. Без него PHY
phy_id reads as zero, stmmac probe fails. Что мы сейчас и видим в
свежей сборке если CV1800B_EPHY_INIT не =y.

Init-последовательность сверена с vendor BSP (`drivers/net/phy/cvitek.c`
функция `cv182xa_phy_config_init` + `dwmac-cvitek.c::bm_eth_reset_phy`):
reset базы (`& ~0x3` + mdelay 2), wrap-последовательность
(0x0900/0x0904/0x0906/0x090e), APB rw_sel и EFUSE-дефолты
(0x5a5a/0x0000/0x0bb0) vendor-точны. Блок MII-page18 (LPF/HPF) это
единственное место, гейтящееся по arch: исправлен с phobos (CV180X) на
mars (CV181X), потому что SG2002 собирается как CV181X/mars (vendor
`sg2002_licheervnano_sd_defconfig`: CONFIG_ARCH_CV181X_ASIC=y,
CONFIG_ARCH_CVITEK_CHIP="mars"). На железе
LicheeRV Nano E подтверждено с mars-сборкой 2026-06-13: end0 на
100baseT/Full, DHCP, ping 0% loss, 0 ошибок интерфейса. Margin-стресс на
длинном/зашумлённом кабеле не гонялся.

### USB Type-C connector

70418 page 4, блок "USB TypeC":

- USB1: USB-C 24-pin connector
- CC1/CC2 pulldowns 5.1K на R34/R35 (UFP role detect)
- D+/D- к SoC USB_DP (pin 69)/USB_DM (pin 70)
- VBUS 5V power input

USB OTG уже поднят патчем `patches/linux/0007-licheerv-nano-usb-dwc2.patch`:
узел `usb@4340000` (`sophgo,cv1800b-usb`, `dr_mode="otg"`) добавлен в
`cv180x.dtsi` и включён во всех 4 board-DTS.

### Audio output PA AW8010A + MIC LMA2718T421

Page 4: U11 "INP/INN/EN/PVDD/AVDD/VOP/VON" pinout это AW8010A audio
power amplifier. Принимает AUD_OUT с SoC pin 4 (PAD_AUD_AOUTR),
выводит VO_P/VO_N (differential speaker output, до speaker pads).

U12 это analog MEMS микрофон LMA2718T421 (output pin AUD_IN
подключается к SoC pin 2 PAD_AUD_AINL_MIC).

Audio уже поднят патчами 0008-0010 (DT-узлы I2S/TDM + internal ADC/DAC
codec, бэкпорт из mainline; активация в board-DTS).

### ADC1 имеет input voltage divider

Page 4: ADC1 pin (SoC 59) выведен на header через делитель R6 10K +
R10 5.1K на GND. То есть:

```
ADC_PIN на header ─ R6 10K ─ ADC1 (SoC 59) ─ R10 5.1K ─ GND
```

Vin на header → ADC1 = Vin × 5.1K / (10K + 5.1K) = Vin × 0.338.
Иначе говоря, при reference 3.3V на pad SoC, максимальное входное
напряжение на header которое не перегружает ADC = 3.3 / 0.338 =
9.76 V.

Реальный диапазон на header это 0..9.76V благодаря делителю (отражено
в `docs/adc_setup.md`, раздел Hardware). Перевод raw в напряжение на
header:

```
voltage_header_mV = raw × 3300 × (10 + 5.1) / 5.1 / 4096
                  = raw × 3300 / 1383.8
                  ≈ raw × 2.385
```

При raw=4095: ~9760 mV. Подходит для измерения 0..10 В battery
monitoring и аналогичных.

## TODO работа на основе schematic

- [x] USER LED сделан через `patches/linux/0018-licheerv-nano-user-led.patch`
  (`GPIO_ACTIVE_HIGH`, default-state off, во всех 4 DTS) + гашение в boot
  через `patches/fsbl/0002`. Прежняя идея active-low (патч 0006) опровергнута
  на железе 2026-06-03 и удалена (полярность active-high верна)
- [ ] Удалить или пометить как unconnected USER button в DTS
  (mainline ошибка, hardware физически отсутствует)
- [ ] Обновить `docs/adc_setup.md` с правильной формулой через
  делитель R6+R10 (множитель ~2.385 для header voltage)
- [ ] Обновить `docs/sg2002_pin_map.md` упоминая ADC divider
- [ ] Когда добавим LCD bring-up, описать AW9962E backlight в
  отдельном узле DTS
- [x] USB OTG узел в `cv180x.dtsi` сделан патчем 0007
- [x] audio I2S+codec сделан патчами 0008-0010
- [ ] MIPI DSI/CSI это отдельная крупная task

## Где лежат скачанные PDF

PDF большие (5..18 MB), не коммитим в репо. Сохранены локально на
build host в `/tmp/sipeed_dl/`:

- `LicheeRV_Nano-70405_Schematic.pdf` (754 KB)
- `LicheeRV_Nano-70415_Schematic.pdf` (781 KB)
- `LicheeRV_Nano-70418_Schematic.pdf` (760 KB)
- `LicheeRV_Nano_v70405_specification_V1.0_en.pdf` (645 KB)
- `SG2002_Preliminary_Datasheet_V1.0-alpha_CN.pdf` (8 MB)

TRM SG2002 (18.5 MB) пока не скачан. Для cкачивания при необходимости:

```
curl -s -A "Mozilla/5.0" \
  "https://api.dl.sipeed.com/file/download?file_url=LICHEE/LicheeRV_Nano/07_Datasheet/SG2002_TRM_V1.0-alpha.pdf" \
  -o /tmp/sipeed_dl/SG2002_TRM.pdf
```
