# SG2002 / LicheeRV Nano pin map

Сводка пинов SoC Sophgo SG2002 в корпусе QFN-38 (вариант LicheeRV
Nano) и их распиновка на 2x14-pin header Sipeed LicheeRV Nano.
Документ собран из:

- `SG2002_QFN_38_GPIO_List.xlsx` (sophgo-doc, sg2002_hardware)
  лист GPIO_List, источник истины по pin functions
- `SG2002_PINOUT.xlsx` (sophgo-doc, sg2002_hardware) лист
  "2. 功能信號表(QFN)" таблица функциональных сигналов с pinmux register
  адресами
- RV_Nano_3.jpg из Sipeed wiki
  (https://wiki.sipeed.com/hardware/en/lichee/assets/RV_Nano/intro/RV_Nano_3.jpg)
  распиновка 2x14 header от Sipeed (с label'ами их собственной
  нумерации, не всегда совпадают с SoC pin nomenclature)
- страница peripheral Sipeed wiki
  (https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/5_peripheral.html)
  справка Sipeed по периферии и pinmux регистрам

## TL;DR доступности периферии

| Подсистема | На header физически | Текущий статус |
|---|---|---|
| UART0 console | да (A16/A17 = SoC 18/19) | active, kernel console |
| UART1 | да (GPIOA 18/19 = SoC 26/27) | active, /dev/ttyS1 |
| UART2 | да (GPIOA 28/29 = SoC 28/29) | active, /dev/ttyS2 |
| UART3 | нет (мультиплексирован с I2C1+SDIO Wi-Fi) | пропущен |
| UART4 | нет (Sipeed не выводит) | пропущен |
| I2C1 | да (SD1_D3 + SD1_D0 = SoC 51+54) | active, /dev/i2c-1 |
| I2C3 | да (SD1_CLK + SD1_CMD = SoC 56+55) | active, /dev/i2c-3 |
| I2C2 | нет (на MIPI TX пинах) | пропущен |
| I2C4 | нет (на MIPI RX/TX пинах) | пропущен |
| SPI0 | нет (на SD0 = boot device) | пропущен |
| SPI1 | нет (на ETH PHY и MIPI RX пинах) | пропущен |
| SPI2 | теоретически да на SD1 пинах, но 100% overlap с I2C1+I2C3 | заблокирован |
| SPI_NOR/SPI_NAND | нет (на EMMC контроллере, отдельный SoC блок) | не применимо |
| PWM[0..15] | все 16 каналов выведены только как alt пинов UART/I2C | заблокирован |
| PWM0_BUCK | нет (internal power buck pad SoC 58) | не выведен |
| ADC1 | да (отдельный SoC pin 59) | в DTS okay, не проверен |
| Ethernet PHY | да на E/WE (SoC pins 62-65) | active на E/WE |
| SDIO0 (boot SD) | да (SoC 6-12) | active как boot device |
| SDIO1 (Wi-Fi AIC8800) | да на W/WE (SoC 51-56) | active на W/WE |
| USB OTG | да (SoC pin 60) | active, DWC2 dual-role + ACM gadget |
| Audio mic | на плате (LMA2718T421 MEMS, аналоговый, SoC pin AUD_AINL_MIC) | работает (см. `docs/audio_setup.md`) |
| Audio speaker | на header (VOP/VON выход AW8010A amp, динамик внешний 8Ω 1Вт) | работает (SPK_EN на время playback) |
| GPIOA xx | XGPIOA[NN], gpiochip0 | active |
| GPIOC xx | XGPIOC[NN] на MIPI пинах, gpiochip2 | active |
| GPIOB xx | XGPIOB[NN] на ETH PHY пинах, gpiochip1 | active |
| PWR_GPIO xx | GRTC domain, gpiochip3 | active |

## Распиновка 2x14 header (по Sipeed RV_Nano_3.jpg)

![Распиновка 2x14 header LicheeRV Nano (Sipeed RV_Nano_3.jpg)](https://wiki.sipeed.com/hardware/en/lichee/assets/RV_Nano/intro/RV_Nano_3.jpg)

Header расположен по двум сторонам платы с шагом 2.54 мм и расстоянием
между гребёнками 800 mil. Direction нумерации с верхнего pin вниз.

### Левая сторона (14 pins)

| Header label | SoC pin | SoC pad name | Альтернативные функции | Текущее назначение |
|---|---|---|---|---|
| PWM5 / UART0 RX / GPIOA 17 | 19 | UART0_RX | XGPIOA[17], PWM[5], CAM_MCLK0 | UART0 RX kernel console |
| PWM4 / UART0 TX / GPIOA 16 | 18 | UART0_TX | XGPIOA[16], PWM[4], CAM_MCLK1, UART1_TX (alt) | UART0 TX kernel console |
| GND | - | - | - | GND |
| GPIOA 15 | 17 | SPK_EN | XGPIOA[15], CAM_RST0 | gpiochip0 line 15 (свободен), SoC pad name `SPK_EN` подразумевает enable для AW8010A speaker amp |
| VOP | - | - | AW8010A `VO_P` (Class-D speaker output) | Speaker positive output амплифа, не SoC pin |
| VON | - | - | AW8010A `VO_N` (Class-D speaker output) | Speaker negative output амплифа, не SoC pin |
| EMMC D1 / SPI1 CS / GPIOA 24 | 25 | EMMC_DAT1 | XGPIOA[24], SPINOR_CS_X, SPINAND_CS | gpiochip0 line 24 |
| EMMC CMD / SPI1 MISO / GPIOA 23 | 24 | EMMC_CMD | XGPIOA[23], SPINOR_MISO, SPINAND_MISO | gpiochip0 line 23 |
| EMMC D0 / SPI1 MOSI / GPIOA 25 | 22 | EMMC_DAT0 | XGPIOA[25], SPINOR_MOSI, SPINAND_MOSI | gpiochip0 line 25 |
| EMMC CLK / SPI1 SCK / GPIOA 22 | 21 | EMMC_CLK | XGPIOA[22], SPINOR_SCK, SPINAND_CLK | gpiochip0 line 22 |
| EMMC D2 / GPIOA 26 | 20 | EMMC_DAT2 | XGPIOA[26], SPINOR_HOLD, SPINAND_HOLD | gpiochip0 line 26 |
| 5V | - | - | - | 5V supply |
| 5V | - | - | - | 5V supply |

Sipeed label "SPI1" на левых пинах вводит в заблуждение. Это пины
SPI_NOR/SPI_NAND boot controller'а SG2002 (отдельный SoC блок),
mainline узел `spi1@4190000` ими не управляет. Полноценный general
SPI на header не выведен.

### Правая сторона (14 pins)

| Header label | SoC pin | SoC pad name | Альтернативные функции | Текущее назначение |
|---|---|---|---|---|
| PWM7 / IIC3 SCL / UART1 RX / GPIOA 18 | 27 | JTAG_CPU_TCK | XGPIOA[18], PWM[6], CAM_MCLK1, UART1_RX (alt) | UART1 RX (pinmux 0x6) |
| PWM6 / IIC3 SDA / UART1 TX / GPIOA 19 | 26 | JTAG_CPU_TMS | XGPIOA[19], PWM[7], CAM_MCLK0, UART1_TX (alt) | UART1 TX (pinmux 0x6) |
| GND | - | - | - | GND |
| GPIOA 29 / UART2 RX / IIC1 SDA | 29 | IIC0_SDA | XGPIOA[29], UART1_RX, UART2_RX | UART2 RX (pinmux 0x2) |
| GPIOA 28 / UART2 TX / IIC1 SCL / ADC | 28 | IIC0_SCL | XGPIOA[28], UART1_TX, UART2_TX | UART2 TX (pinmux 0x2) |
| ADC1 | 59 | ADC1 | XGPIOB[3], KEY_COL2 | ADC channel 1 (SAR-ADC) |
| GPIOP 19 / UART3 TX / IIC1 SCL / PWM 4 / SPI2 CS / SDIO1 D3 | 51 | SD1_D3 | PWR_GPIO[18], SPI2_CS_X, IIC1_SCL, UART3_RX, PWM[10] | I2C1 SCL (pinmux 0x2) или SDIO1 D3 на W/WE |
| GPIOP 22 / IIC1 SDA / UART3 RTS / PWM 8 / SPI2 MISO / SDIO1 D1 | 54 | SD1_D0 | PWR_GPIO[21], SPI2_SDI, IIC1_SDA, UART3_RTS, PWM[7] | I2C1 SDA (pinmux 0x2) или SDIO1 D0 на W/WE. Sipeed маркировка SDIO1 D1 на этом пине ошибочна, реально SoC SD1_D0 |
| GPIOP 21 / UART3 CTS / IIC3 SCL / PWM 5 / SPI2 MOSI / SDIO1 CMD | 55 | SD1_CMD | PWR_GPIO[22], SPI2_SDO, IIC3_SCL, UART3_CTS, PWM[8] | I2C3 SDA (pinmux 0x2) или SDIO1 CMD на W/WE |
| GPIOP 20 / UART3 RX / PWM 7 / SPI2 SCK / SDIO1 CLK | 56 | SD1_CLK | PWR_GPIO[23], SPI2_SCK, IIC3_SDA, UART3_TX, PWM[9] | I2C3 SCL (pinmux 0x2) или SDIO1 CLK на W/WE |
| GPIOP 18 | 50 | (вакантный SoC pin на QFN-38) | пин не задействован SoC в QFN-38, заглушка | свободен |
| GPIOA 14 | 15 | SD0_PWR_EN | XGPIOA[14], SDIO0_PWR_EN | user LED (D1 на плате, trigger mmc0) |
| 3V3 | - | - | - | 3.3V supply |

Sipeed label "PWM N" на header привязан к их header convention, не к
SoC PWM channel number. Например header label "PWM 6" на GPIOA 19 это
реально SoC PWM[7]. Сверяйте по SoC pin column.

## Pinmux register layout

Сводная таблица pinmux регистров (FMUX_GPIO_REG_IOCTRL_*) для пинов
header. Полная таблица для всех SoC pins в xlsx файле, здесь только
пины 2x14 header. Адрес = `0x03001000 + offset`.

| SoC pin | SoC pad | Pinmux register | Func0 | Func1 | Func2 | Func3 | Func4 | Func5 | Func6 | Func7 |
|---|---|---|---|---|---|---|---|---|---|---|
| 6 | SD0_CLK | 0x0300_101C | SDIO0_CLK | IIC1_SDA | SPI0_SCK | XGPIOA[7] | - | PWM[15] | EPHY_LNK_LED | DBG[0] |
| 7 | SD0_CMD | 0x0300_1020 | SDIO0_CMD | IIC1_SCL | SPI0_SDO | XGPIOA[8] | - | PWM[14] | EPHY_SPD_LED | DBG[1] |
| 8 | SD0_D0 | 0x0300_1024 | SDIO0_D0 | CAM_MCLK1 | SPI0_SDI | XGPIOA[9] | UART3_TX | PWM[13] | WG0_D0 | DBG[2] |
| 12 | SD0_D3 | 0x0300_1030 | SDIO0_D3 | CAM_MCLK0 | SPI0_CS_X | XGPIOA[12] | UART3_RX | PWM[10] | WG1_D1 | DBG[5] |
| 18 | UART0_TX | 0x0300_104C | UART0_TX | CAM_MCLK1 | PWM[4] | XGPIOA[16] | UART1_TX | AUX1 | - | DBG[6] |
| 19 | UART0_RX | 0x0300_1050 | UART0_RX | CAM_MCLK0 | PWM[5] | XGPIOA[17] | UART1_RX | AUX0 | - | DBG[7] |
| 26 | JTAG_CPU_TMS | 0x0300_1064 | JTAG_TMS | CAM_MCLK0 | PWM[7] | XGPIOA[19] | UART1_RTS | AUX0 | UART1_TX | DBG[9] |
| 27 | JTAG_CPU_TCK | 0x0300_1068 | JTAG_TCK | CAM_MCLK1 | PWM[6] | XGPIOA[18] | UART1_CTS | AUX1 | UART1_RX | DBG[8] |
| 28 | IIC0_SCL | 0x0300_1070 | IIC0_SCL | UART1_TX | UART2_TX | XGPIOA[28] | - | WG0_D0 | - | DBG[10] |
| 29 | IIC0_SDA | 0x0300_1074 | IIC0_SDA | UART1_RX | UART2_RX | XGPIOA[29] | - | WG0_D1 | WG1_D0 | DBG[11] |
| 47 | PWR_GPIO0 | 0x0300_10A4 | PWR_GPIO[0] | UART2_TX | PWR_UART0_TX | - | PWM[8] | - | - | - |
| 48 | PWR_GPIO1 | 0x0300_10A8 | PWR_GPIO[1] | UART2_RX | - | EPHY_LNK_LED | PWM[9] | PWR_IIC_SCL | IIC2_SCL | PWR_MCU_JTAG_TMS |
| 49 | PWR_GPIO2 | 0x0300_10AC | PWR_GPIO[2] | - | PWR_SECTICK | EPHY_SPD_LED | PWM[10] | PWR_IIC_SDA | IIC2_SDA | PWR_MCU_JTAG_TCK |
| 51 | SD1_D3 | 0x0300_10D0 | PWR_SD1_D3 | SPI2_CS_X | IIC1_SCL | PWR_GPIO[18] | CAM_MCLK0 | UART3_CTS | PWR_SPINOR1_CS_X | PWM[4] |
| 52 | SD1_D2 | 0x0300_10D4 | PWR_SD1_D2 | IIC1_SCL | UART2_TX | PWR_GPIO[19] | CAM_MCLK0 | UART3_TX | PWR_SPINOR1_HOLD | PWM[5] |
| 53 | SD1_D1 | 0x0300_10D8 | PWR_SD1_D1 | IIC1_SDA | UART2_RX | PWR_GPIO[20] | CAM_MCLK1 | UART3_RX | PWR_SPINOR1_WP | PWM[6] |
| 54 | SD1_D0 | 0x0300_10DC | PWR_SD1_D0 | SPI2_SDI | IIC1_SDA | PWR_GPIO[21] | CAM_MCLK1 | UART3_RTS | PWR_SPINOR1_MISO | PWM[7] |
| 55 | SD1_CMD | 0x0300_10E0 | PWR_SD1_CMD | SPI2_SDO | IIC3_SCL | PWR_GPIO[22] | - | EPHY_LNK_LED | PWR_SPINOR1_MOSI | PWM[8] |
| 56 | SD1_CLK | 0x0300_10E4 | PWR_SD1_CLK | SPI2_SCK | IIC3_SDA | PWR_GPIO[23] | - | EPHY_SPD_LED | PWR_SPINOR1_SCK | PWM[9] |
| 59 | ADC1 | (no pinmux, ADC dedicated) | ADC1 (SAR) | - | - | XGPIOB[3] | KEY_COL2 | - | - | - |

Используемые в текущей сборке pinmux установки (задаются pinctrl-группами
board-DTS, патч `patches/linux/0021`; I2C1/I2C3 только на B/E, на W/WE их
пады SD1 заняты SDIO Wi-Fi):

```
0x0300_1064 = 0x6  # GPIOA 19 UART1 TX (pad JTAG_CPU_TMS Func6)
0x0300_1068 = 0x6  # GPIOA 18 UART1 RX (pad JTAG_CPU_TCK Func6)
0x0300_1070 = 0x2  # GPIOA 28 UART2 TX (pad IIC0_SCL Func2)
0x0300_1074 = 0x2  # GPIOA 29 UART2 RX (pad IIC0_SDA Func2)
0x0300_10D0 = 0x2  # GPIOP 19 I2C1 SCL (pad SD1_D3 Func2)
0x0300_10DC = 0x2  # GPIOP 22 I2C1 SDA (pad SD1_D0 Func2)
0x0300_10E0 = 0x2  # GPIOP 21 I2C3 SCL (pad SD1_CMD Func2)
0x0300_10E4 = 0x2  # GPIOP 20 I2C3 SDA (pad SD1_CLK Func2)
```

## Конфликты пинов

Один SoC pin не может выполнять две функции одновременно. На 2x14
header переключение pinmux на одну функцию ломает другую. Реальные
конфликты по подсистемам:

- I2C1+I2C3 (current) vs SPI2 (один SD1 блок пинов)
- I2C1+I2C3 (current) vs UART3 (один SD1 блок пинов, плюс SDIO Wi-Fi
  на W/WE)
- I2C1+I2C3 (current) vs PWM[4]/PWM[7]/PWM[8]/PWM[9] (тот же SD1)
- UART1 (current) vs PWM[6]/PWM[7] (GPIOA 18/19)
- UART2 (current) vs PWM[4]/PWM[5] нет (PWM на UART0 пинах не на
  UART2). UART2 не блокирует PWM[6]/PWM[7]
- UART0 console vs PWM[4]/PWM[5] (GPIOA 16/17). Здесь выбор между
  debug-консолью и PWM
- На W/WE: SDIO1 (AIC8800) занимает весь SD1 блок, I2C1+I2C3 на
  header физически не работают (PHY-уровне overlap с SDIO)

## Свободные пины header (current bring-up)

После активации UART0+UART1+UART2+I2C1+I2C3, на 2x14 header остаются
неконфликтные пины:

- Левая сторона: GPIOA 22/23/24/25/26 (EMMC*) как pure GPIO через
  gpiochip0. eMMC controller узел в DTS disabled, эти пины свободны
- Левая сторона: GPIOA 15 (SPK_EN pin SoC 17) свободен как gpiochip0
  line 15
- VOP/VON это выходы AW8010A speaker amp (Class-D), не пины SoC, как
  GPIO недоступны
- Правая сторона: GPIOP 18 свободен (SoC pin не задействован QFN-38)
- Правая сторона: GPIOA 14 уже user LED, но через sysfs можно
  переключить trigger
- ADC1 (SoC pin 59) свободен, не overlapping с GPIOA 28 пином, это
  отдельный header pin рядом

## Аппаратное расположение GPIO chips

mainline gpio-сubsystem видит 4 chip'а через mainline pinctrl-sg2002:

| chip | offset | домен | пример пинов на header |
|---|---|---|---|
| gpiochip0 | XGPIOA | EMMC/SD0/console power domain | GPIOA 14/15/22-26/28/29 |
| gpiochip1 | XGPIOB | ETH PHY power domain (только E/WE) | XGPIOB[3] (ADC pin) |
| gpiochip2 | XGPIOC | MIPI power domain (camera/display) | header не выводит |
| gpiochip3 | PWR_GPIO | RTC domain (always-on) | GPIOP 19-23 |

Управление через `gpioinfo`, `gpioset`, `gpioget` (libgpiod в EXTRA_PKGS).

## Дальнейшая работа

Раскрыть в bring-up по убыванию приоритета:

- ADC1 проверить mainline `iio:device0` (узел `&saradc` уже okay)
- GPIO документация и тесты через libgpiod
- I2C4 + Goodix touchscreen (если есть LCD модуль)
- USB OTG (узел `usb@` нужно добавить, mainline пока не описывает)
- MIPI DSI display (vendor backport нужен)
- MIPI CSI camera (vendor backport нужен)

## Связанные документы

- `docs/uart_setup.md` это UART1/UART2 pinmux
- `docs/i2c_setup.md` это I2C1/I2C3 pinmux
- `docs/adc_setup.md` это ADC1 channel на header
- `docs/gpio_setup.md` это GPIO chips и USER LED/button
- `docs/usb_setup.md` это USB OTG pinout (Type-C)
- `docs/audio_setup.md` это audio pins (AUD_AINL_MIC, AUD_AOUTR, SPK_EN)
- https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/5_peripheral.html
  это vendor pinout reference
