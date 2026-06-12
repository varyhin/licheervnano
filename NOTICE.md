# Лицензии и происхождение компонентов

Лицензия MIT в файле LICENSE распространяется только на собственные файлы
проекта: Makefile, manifest/, scripts/, extlinux/, docs/, README.

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
- aic8800_u03/ это прошивка Wi-Fi/BT чипа AIC8800D80 из vendor SDK AIC

Блобы перераспространяются в составе проекта так же, как это делает
исходный SDK Sipeed. При несогласии правообладателя каталог firmware/
подлежит замене на инструкцию по извлечению из SDK.
