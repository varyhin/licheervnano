# Лицензии и происхождение компонентов

Лицензия MIT в файле LICENSE распространяется только на собственные файлы
проекта: Makefile, manifest/, scripts/, extlinux/, README, NOTICE.md и
текст docs/. Каталоги docs/assets/ и docs/datasheets/ под MIT не подпадают,
их происхождение описано ниже.

## Снапшоты сторонних исходников (src/)

Каждый каталог src/<имя> это verbatim-снапшот стороннего проекта на пине
из manifest/sources.mk и сохраняет лицензию своего upstream (файлы
LICENSE/COPYING внутри). Точное происхождение указано в сообщении
импорт-коммита каждого каталога.

| Каталог | Upstream | Лицензия upstream |
|---|---|---|
| src/u-boot | source.denx.de/u-boot/u-boot | GPL-2.0+ |
| src/opensbi | github.com/riscv-software-src/opensbi | BSD-2-Clause |
| src/fiptool | github.com/sophgo/fiptool | см. upstream |
| src/licheerv-nano-build-vendor | github.com/sipeed/LicheeRV-Nano-Build | BSD-3-Clause (TF-A) и др. |
| src/aic8800-vendor | github.com/sipeed/LicheeRV-Nano-Build | GPL-2.0 (kernel-модули) |
| src/cvitek-tpu-vendor | github.com/sipeed/LicheeRV-Nano-Build | GPL-2.0 (kernel-модуль) |

Снапшоты userspace TPU-стека (cviruntime, cvikernel, cvibuilder, cnpy,
zlib) вынесены в отдельный репозиторий вместе со своим NOTICE.md.

Патчи в patches/ и файлы overlay/ являются производными от деревьев,
которые они модифицируют, и наследуют их лицензии.

## Бинарные блобы (firmware/)

- ddr_param.bin и cvirtos.bin это закрытые vendor-блобы из
  sipeed/LicheeRV-Nano-Build (DDR-параметры и FreeRTOS малого ядра,
  суммарно 21 KiB), распространяются verbatim, замены не существует
- cv181x.bin это наша сборка BL2 из исходников fsbl (src/licheerv-nano-build-vendor)
- cv181x-vendor.bin это reference-блоб BL2 из того же SDK (fallback)
- aic8800_u03/ и aic8800d80_u02/ это прошивка Wi-Fi/BT радиомодулей,
  правообладатель AICSemi. Плата W/WE встречается в двух ревизиях с
  разными чипами, образ несёт оба комплекта. `aic8800_u03/` (13 файлов)
  это AIC8801 U03, `aic8800d80_u02/` (10 файлов) это AIC8800D80.
  Блобы взяты побитово (sha256 совпадает) из зеркала
  gtxaspec/aic8800-wifi, каталоги SDIO/driver_fw/fw/aic8800/ и
  SDIO/driver_fw/fw/aic8800D80/, которое перераспространяет прошивку AIC

Блобы перераспространяются в составе проекта так же, как это делает
исходный SDK Sipeed. При несогласии правообладателя каталог firmware/
подлежит замене на инструкцию по извлечению из SDK.

## Изображения (docs/assets/)

Все три файла взяты из публичной Sipeed wiki (wiki.sipeed.com) и
перераспространяются как справочный материал. При несогласии
правообладателя файлы подлежат замене на внешние ссылки.

- RV_Nano_1.jpg это фото платы (фронт, оборот, вариант с Wi-Fi-модулем)
- RV_Nano_3.jpg это распиновка 2x14 header
- RV_Nano_4.jpg это размеченная схема размещения компонентов (top/bottom)

## Документация вендоров (docs/datasheets/)

Проприетарные документы Sophgo и Sipeed, включены как референс bring-up,
чтобы цитаты вида «по TRM гл.20 Table 20.26» в преамбулах патчей и в docs
были проверяемы внутри репозитория. Имена, размеры, SHA256 и источник
скачивания перечислены в docs/datasheets/README.md.

- sg2002_trm_en.pdf это Sophgo SG2002 Technical Reference Manual,
  правообладатель Sophgo
- LicheeRV_Nano-70405/70415/70418_Schematic.pdf это схемы платы,
  правообладатель Sipeed

Обе группы взяты из официального файлохранилища Sipeed
(cn.dl.sipeed.com, подкаталоги 02_Schematic и 07_Datasheet), которое
раздаёт их публично. При несогласии правообладателя каталог
docs/datasheets/ подлежит замене на инструкцию по скачиванию с
сохранением таблицы SHA256.
