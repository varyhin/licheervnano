# Datasheets и схемы (референс)

Авторитетные документы Sophgo/Sipeed для сверки регистров, pinmux, memory map,
карты прерываний и разводки платы. Хранятся в репозитории, чтобы цитаты вида
«по TRM гл.20 Table 20.26» в преамбулах патчей и в docs были repo-verifiable.
Каждая цитата привязана к конкретному файлу по SHA256 из таблицы ниже.

Документы проприетарные (Sophgo/Sipeed), включены как референс bring-up.

## Файлы

| Файл | Что это | Rev / дата | Размер | SHA256 |
|---|---|---|---|---|
| `sg2002_trm_en.pdf` | Sophgo SG2002 Technical Reference Manual (918 стр) | en | 7.7M | `619ee0a22eac8294712ed635d08c70ed3f9a75fe8e93525dfa5e6c2a11793b21` |
| `LicheeRV_Nano-70418_Schematic.pdf` | Схема LicheeRV Nano, текущая ревизия | 1.4 / 24-3-28 | 760K | `7fdc7cbcda36a676ef73e3525f61e9ddec7507cca76828490225143696284efe` |
| `LicheeRV_Nano-70415_Schematic.pdf` | Схема LicheeRV Nano, предыдущая ревизия | 1.3 / 24-2-28 | 764K | `ee8211a4c75c40f2327114a93b6d4aa4a80b8a6cf057b5eda5bb5a64365e4955` |
| `LicheeRV_Nano-70405_Schematic.pdf` | Схема LicheeRV Nano, ранняя ревизия | 1.2 / 23-12-16 | 756K | `b09ec99069e7f696498b3501785f5296fd0ecaed6d1895d16de2c2e057c2fd19` |

Аудит и сверка велись по 70418 (Rev 1.4) и `sg2002_trm_en.pdf`. Ревизии
70405/70415 включены как референс для более ранних плат.

## Источник

Документы взяты из официального ресурс-каталога Sipeed для LicheeRV Nano
(`http://cn.dl.sipeed.com/shareURL/LICHEE/LicheeRV_Nano/`), подкаталоги
`02_Schematic` (схемы) и `07_Datasheet` (TRM). Файлы крупнее 10 МБ Sipeed
отдаёт через облако.

- Baidu: `https://pan.baidu.com/s/1-r6V352TIN8eqiFEIsUQoA?pwd=yskz` (пароль `yskz`)
- MEGA: `https://mega.nz/folder/A8g1Hb4J#WcuoqvbpasKlVB8-YEpWPA`

Проверка целостности после скачивания.

```sh
sha256sum -c <<'SUMS'
619ee0a22eac8294712ed635d08c70ed3f9a75fe8e93525dfa5e6c2a11793b21  sg2002_trm_en.pdf
7fdc7cbcda36a676ef73e3525f61e9ddec7507cca76828490225143696284efe  LicheeRV_Nano-70418_Schematic.pdf
ee8211a4c75c40f2327114a93b6d4aa4a80b8a6cf057b5eda5bb5a64365e4955  LicheeRV_Nano-70415_Schematic.pdf
b09ec99069e7f696498b3501785f5296fd0ecaed6d1895d16de2c2e057c2fd19  LicheeRV_Nano-70405_Schematic.pdf
SUMS
```

## Карта раздел TRM -> где цитируется

- гл.3 System Architecture (memory map Table 3.4, interrupt map Table 3.2) это `0007` (USB IRQ 30), `0017` (TPU IRQ 75/76, reg-базы в Reserved)
- гл.6 RTC (fc_coarse_cal 0x044, fc_fine_cal 0x050) это `0022` (FC bitfield split)
- гл.9 System Controller (usb_phy_ctrl_reg Table 9.5, DMA Channel Mapping Table 9.1) это `0007` (USB PHY ctrl), `0008` (dmamux devid)
- гл.10 PINMUX (Table 10.35 function select, Table 10.1 ADC) это `0004`/`0005`/`0021` (I2C/UART funcsel), `0012` (SPK_EN reset 0x3), `docs/sg2002_pin_map.md`, `docs/gpio_setup.md` (PWR_GPIO = RTCSYS_GPIO)
- гл.20 Audio Interface (I2S_CLK_CTRL0 Table 20.26, rxadc_ana3 Table 20.38) это `0016` (BCLK_OUT_FORCE_EN reset 1, CTUNE 0xC)
- гл.21.6 USB DRD это `0007` (FIFO-потолки в TRM не публикуются)
- гл.21.7 SARADC это `docs/adc_setup.md` (3 канала, один пад ADC1)

Схема 70418 page 4 (блоки 10/100M PHY, USB TypeC, PA, MIC) это
`docs/sipeed_resources.md` (трансформаторы Ethernet U7/U8, USB D+/D- pins 69/70,
PA AW8010A U11, MIC U12).
