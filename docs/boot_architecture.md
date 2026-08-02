# Архитектура загрузки (boot)

Разбор того, как LicheeRV Nano грузится с microSD, где проходит граница ответственности BootROM и U-Boot, и что из этого следует для идеи вынести boot на ext4. Записка справочная, не пошаговая инструкция.

Статус: текущая раскладка (FAT16 p1 + ext4 p2) собрана пайплайном `make image` и проверена на железе. Перенос boot на ext4 разобран по исходникам и первоисточникам, но не реализован.

## Цепочка загрузки

```
BootROM (mask ROM SG2002)
  → читает fip.bin (контейнер CVBL01) с носителя
  → FSBL (bl2) внутри fip.bin
     → DDR init, дочитывает остальные части fip.bin по offset
  → OpenSBI (fw_dynamic) внутри fip.bin
  → U-Boot proper внутри fip.bin
     → run distro_bootcmd → скан разделов → sysboot extlinux
  → ядро Image + dtb (сейчас с FAT, цель ext4)
```

`fip.bin` это единый подписанный контейнер с магией `CVBL01\n`, в который упакованы FSBL, OpenSBI и U-Boot. Собирается из `build/u-boot/u-boot.bin`, `fw_dynamic.bin`, `fsbl/.../bl2.bin` и прочего таргетом `fip` в `Makefile`.

## Текущая раскладка SD

Из `Makefile` (таргет `_image_pack`), таблица MBR на два раздела.

| Раздел | ФС | Границы | Содержимое |
|--------|-----|---------|-----------|
| p1 `BOOT` | FAT16, флаг boot | 1MiB–132MiB | `fip.bin`, `Image`, 4 dtb (b/e/w/we), `extlinux/extlinux.conf` |
| p2 `root` | ext4 | 132MiB–конец | rootfs Debian trixie |

`extlinux.conf` грузит ядро с p1, `root=/dev/mmcblk0p2` указывает rootfs на ext4. Замер собранного `images/licheervnano.img` это магия `CVBL01` ровно один раз, на секторе 2368 внутри FAT, сырой копии в младших секторах нет.

## Ограничение BootROM: fip.bin только в FAT (на SD)

На первой ступени `fip.bin` читает BootROM, и ext4 он не понимает. Способ поиска FIP зависит от носителя, и для SD это файл в FAT.

| Носитель | Где BootROM берёт fip.bin |
|----------|---------------------------|
| SD | файл `fip.bin` в FAT-разделе (FAT16/FAT32) |
| eMMC | аппаратный boot-раздел `mmcblk0boot0`, offset 1M (сырое чтение) |
| SPI-NAND | скан блоков по магии (состояние `ATF_STATE_SPINAND_SCAN_FIP_BLKS`) |
| SPI-NOR | фиксированный offset |

Доказательная база:

- замер `images/licheervnano.img`: `CVBL01` только внутри FAT, образ грузится на железе, значит FIP прочитан из FAT.
- две разные геометрии FAT грузятся (наш FAT16 кладёт FIP на сектор 2368, вендорный `genimage` использует FAT тип 0x0C). Будь чтение по фиксированному LBA, разные геометрии не загрузились бы, значит BootROM находит файл динамически.
- вендорный док Production Burning требует «A FAT32 format TF Card» и «Put fip.bin ... in the SD card».
- FSBL `bl2` дочитывает OpenSBI/U-Boot/DDR-параметры через `p_rom_api_load_image(buf, offset, size)` по байтовому смещению внутри FIP (`fsbl/plat/cv181x/bl2/bl2_opt.c` в vendor SDK sipeed/LicheeRV-Nano-Build), отсюда требование непрерывности файла `fip.bin`.
- TRM SG2002 глава 4 Boot and Upgrade: страпы EMMC_DAT3/DAT0 выбирают SPI-NOR/SPI-NAND/eMMC, SD идёт как image burning mode, домены SD0 и eMMC делят IO-питание.

Следствие: на этой плате (только microSD) от FAT под `fip.bin` уйти нельзя. Ограничение касается только `fip.bin` (~600 КБ), ядро и dtb грузит уже U-Boot.

## Как U-Boot находит ядро

`BOOTCOMMAND="run distro_bootcmd"`, наш U-Boot это mainline-порт `board/sophgo/licheerv_nano`, env только в RAM (`CONFIG_ENV_IS_NOWHERE`, персистентного env нет). distro-скан перебирает разделы и пробует extlinux.

Ключевые факты, проверены по `src/u-boot`:

- скан разделов это `part list ${devtype} ${devnum} -bootable devplist`, то есть перебираются ТОЛЬКО разделы с MBR-флагом boot (`include/config_distro_bootcmd.h`). Сейчас флаг на p1, поэтому скан видит только p1.
- префиксы поиска это `/` и `/boot/`, имя файла это `extlinux/extlinux.conf`, тип ФС в `sysboot` это `any` (ext4 распознаётся, `CMD_EXT4_WRITE` собран).
- резолв путей `kernel`/`fdt` (`boot/pxe_utils.c`, функция `get_relfile`, вызов `sysboot` с `allow_abs_path=true` в `cmd/sysboot.c`):
  - путь с ведущим `/` берётся от корня раздела с конфигом, каталог конфига не подставляется.
  - путь без `/` берётся относительно каталога `extlinux.conf`.
- `boot.scr` тоже поддержан, distro-скан ищет его на загрузочном разделе (`boot_scripts=boot.scr.uimg boot.scr`).

## Наш стек против вендорного

Два разных U-Boot, не путать при решениях по boot.

| | Наш проект | Вендор (cvitek SDK / Sipeed / Milk-V buildroot) |
|---|---|---|
| U-Boot | mainline-порт `board/sophgo/licheerv_nano` | форк cvitek |
| Модель boot | `distro_bootcmd` + extlinux | FIT `boot.sd` + фикс. bootcmd |
| boot.scr | поддержан (штатный механизм upstream) | не используется |
| extlinux | используется | не используется |
| Ядро и dtb | сейчас на FAT, цель ext4 | всегда на FAT внутри FIT |

Вендорный boot-блоб это FIT-образ. Сборка это `multi.its` → `mkimage` → `boot.itb`, который кладётся на FAT как `boot.sd` рядом с `fip.bin` (vendor SDK sipeed/LicheeRV-Nano-Build, `build/common_functions.sh`, `build/Makefile`). Вендорный bootcmd из реального boot-лога это `run distro_bootcmd || run sdboot || run sdbootauto`, где `sdboot` это `fatload mmc ${sddev} ${uImage_addr} boot.sd; bootm ${uImage_addr}#config-...`. distro пробуется первым, но `extlinux.conf` вендор не кладёт, поэтому всё уходит в FIT-ветку. Вендор держит весь boot на FAT и ext4 для загрузки не использует, то есть его модель противоположна нашей цели.

## Перенос boot на ext4

Цель это убрать 131-мегабайтный FAT и держать `Image`+dtb+`extlinux` на ext4, оставив на FAT только обязательный `fip.bin`.

Вариант B (убрать FAT полностью, `fip.bin` сырым offset, единственный ext4) невозможен, потому что BootROM на SD читает `fip.bin` только из FAT. Реализуемо только через Вариант A (крошечный FAT под `fip.bin` + всё остальное на ext4).

Целевая раскладка для A:

- p1 крошечный FAT (~16 МБ), флаг boot, только `fip.bin`
- p2 ext4, в `/boot` лежат `Image`, dtb и `extlinux/extlinux.conf`, пути в конфиге абсолютные `/boot/Image` и `/boot/sg2002-licheerv-nano-*.dtb`, `root=/dev/mmcblk0p2` не меняется

Загвоздка это скан по `-bootable`. Флаг boot нужен BootROM на FAT p1, но тогда distro-скан не дойдёт до ext4 p2. Три способа закрыть, BootROM-видимую часть при этом не трогаем.

| Способ | Правка исходника | На FAT | Риск BootROM |
|--------|------------------|--------|--------------|
| `boot.scr` на FAT, который делает `sysboot mmc 0:2 ... /boot/extlinux/extlinux.conf` | нет | `fip.bin` + `boot.scr` | нет |
| перенос MBR-флага boot с p1 на p2 (только `parted` в Makefile) | нет | только `fip.bin` | да, нужен 1 hw-тест что BootROM грузится с неактивного FAT |
| патч `SCAN_DEV_FOR_BOOT_PARTS` в `include/configs/licheerv_nano.h` (скан всех разделов, без `-bootable`) | да | только `fip.bin` | нет |

`boot.scr` безопасен по части коллизии адресов, так как `run_command_list` копирует скрипт в свой буфер перед исполнением (`common/cli.c`), и `sysboot` не портит исполняемый скрипт.

Приоритетный вариант это `boot.scr`. Обоснование:

- ноль правок исходника U-Boot, скрипт это штатная точка расширения distro-скана, генерится на этапе образа через `mkimage -T script`.
- BootROM-видимая часть (активный FAT p1 с `fip.bin`) остаётся байт-в-байт как в рабочем образе, никаких новых допущений про BootROM.
- ноль аппаратного риска, в отличие от переноса флага boot на p2, который до hw-теста остаётся гипотезой.
- меню вариантов B/E/W/WE сохраняется на ext4, так как `boot.scr` передаёт управление в `sysboot` на `/boot/extlinux/extlinux.conf`.

Плата это крошечный `boot.scr` остаётся на FAT, то есть «совсем ничего кроме fip.bin» не достигается. Если это принципиально, альтернатива без правки исходника это перенос флага boot на p2, но он требует hw-теста.

## Известные ограничения

- Полностью без FAT на SD загрузиться нельзя, минимальный FAT под `fip.bin` обязателен.
- `fip.bin` должен лежать на FAT непрерывным файлом, свежий FAT с записью `fip.bin` первым это гарантирует.
- Персистентного env у U-Boot нет, поправить скан сохранённой переменной невозможно, плюс `part list -bootable` перезатирает `devplist` на каждом заходе.
- Перенос флага boot на p2 опирается на непроверенное допущение, что BootROM находит `fip.bin` на неактивном FAT-разделе, до hw-теста это гипотеза.
- При смене раскладки нужно синхронно править `docs/expand_rootfs.md`, где зашиты границы p1 (1MiB–132MiB) и старт p2 (сектор 270336).

## См. также

- `docs/sdcard_setup.md` это дерево тактов SD0, базовый такт SDHCI в U-Boot и методика снятия регистров контроллера с приглашения
- `docs/expand_rootfs.md` это расширение rootfs-раздела на полный размер карты
- `Makefile` таргеты `fip` и `_image_pack` это сборка `fip.bin` и упаковка образа
- `extlinux/extlinux.conf` это меню вариантов платы B/E/W/WE
