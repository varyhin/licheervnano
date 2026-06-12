# licheervnano

Русский | [English](README.en.md) | [中文](README.zh.md)

Полный сборочный конвейер mainline-стека для платы Sipeed LicheeRV Nano
(SoC Sophgo SG2002, RISC-V C906 1 ГГц, TPU 0.5 TOPS INT8). Из одного
`make image` получается загрузочный SD-образ с цепочкой
FSBL → OpenSBI → U-Boot → Linux 6.18 → Debian 13 и поддержкой четырёх
вариантов платы: B (без сети), E (Ethernet), W (Wi-Fi 6), WE (Ethernet + Wi-Fi 6).

Всё проверено на железе по UART. Закрытый vendor-footprint минимален:
21 KiB блобов загрузки (DDR-параметры и FreeRTOS малого ядра) плюс
прошивка радиочипа AIC8800D80 для W/WE.

## Модель исходников

Все компоненты, кроме ядра Linux, лежат снапшотами в `src/` этого
репозитория. Сборка по умолчанию использует их и не ходит в сеть.
У каждого компонента в `manifest/sources.mk` зафиксирован пин SHA и
официальный URL, поэтому источник всегда можно переключить:

- `make refetch COMP=u-boot SOURCE=upstream` перекачивает дерево пина из
  официального репозитория поверх `src/u-boot`
- пустой `git status` после перекачки доказывает, что снапшот идентичен
  upstream (проверка дрейфа бесплатно)

Ядро в репозитории не хранится, `make fetch-linux` клонирует
`v6.18.29` с kernel.org и сверяет SHA с пином. Rootfs собирается
debootstrap-ом из deb.debian.org.

| Компонент | Версия / пин | Назначение |
|---|---|---|
| linux | v6.18.29 (клонируется) | ядро |
| u-boot | v2025.10 | загрузчик S-mode |
| opensbi | v1.8.1 | SBI-прошивка M-mode |
| fiptool | 7f59889 | упаковка FIP-контейнера |
| licheerv-nano-build-vendor | d4003f15 | FSBL (vendor TF-A), блобы |
| aic8800-vendor | d4003f15 | Wi-Fi 6 / BT драйвер SDIO |
| cvitek-tpu-vendor | d4003f15 | kernel-драйвер TPU |

Userspace TPU-стек (cviruntime, cvikernel, cvibuilder, cnpy, zlib,
контейнер tpu-mlir, бенч-кит) в этот репозиторий не входит и
ведётся отдельно.

## Быстрый старт

Хост: Debian 13 amd64 (или совместимый), root для debootstrap и сборки образа.

```sh
apt install gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
  device-tree-compiler u-boot-tools build-essential bc bison flex \
  libssl-dev libelf-dev libncurses-dev python3 parted dosfstools rsync \
  debootstrap qemu-user-static binfmt-support git

git clone <этот репозиторий> && cd licheervnano
make rootfs        # debootstrap Debian 13 + пакеты (~5 мин, интернет)
make image         # полная сборка: патчи, u-boot, opensbi, fsbl, ядро,
                   # модули, fip, упаковка SD-образа
```

Результат: `images/licheervnano.img` и `images/licheervnano.img.gz`.
Прошивка: balenaEtcher понимает `.img.gz` напрямую, либо
`dd if=images/licheervnano.img of=/dev/sdX bs=4M conv=fsync`.

Консоль: UART0, 115200 8N1. Вариант платы выбирается в extlinux-меню
U-Boot при загрузке (по умолчанию WE, таймаут несколько секунд).
Логин root, пароль sipeed (меняется переменной `ROOT_PASSWORD`).

Отдельные шаги: `make help`.

## Структура репозитория

| Каталог | Назначение |
|---|---|
| `manifest/` | пины SHA и URL всех компонентов |
| `src/` | снапшоты исходников (ядро клонируется сюда же) |
| `patches/` | локальные патчи поверх чистых снапшотов (формат diff -u) |
| `overlay/` | новые файлы, копируемые поверх снапшотов при сборке |
| `firmware/` | vendor-блобы + самосборный FSBL (см. NOTICE.md) |
| `extlinux/` | меню загрузки четырёх вариантов платы |
| `scripts/` | refetch, usb-gadget, гигиена SSH-ключей |
| `docs/` | руководства по периферии и сборке |
| `build/`, `rootfs/`, `images/` | derived-артефакты, в .gitignore |

## Патчи и overlay

Снапшоты в `src/` всегда чистые. Локальные изменения живут только в
`patches/` (истинные модификации upstream-файлов, строго формат
`diff -u`, без строк index) и `overlay/` (новые файлы). `make
patches-apply` накладывает их на рабочее дерево, `make patches-revert`
возвращает чистое состояние. Применение проверяется по `git status`,
а не по коду возврата: `git apply` молча пропускает патчи формата
`git diff` с blob-index в этой раскладке.

`make patches-check` ложно падает на цепочке create-затем-modify
(патч 0001 создаёт board-DTS, поздние патчи их меняют). Реальная
проверка это `make patches-apply` на чистом дереве.

## Обновление версии компонента

1. Обновить пин в `manifest/sources.mk`.
2. `make refetch COMP=<имя> SOURCE=upstream`.
3. Проверить патчи (`make patches-apply`), собрать, проверить на железе.
4. Закоммитить изменение `src/<имя>` и манифеста одним коммитом.

## Периферия

Состояние на варианте WE, всё перечисленное проверено на плате.

| Периферия | Статус | Документ |
|---|---|---|
| UART, GPIO, pinmux | работает | [docs/uart_setup.md](docs/uart_setup.md), [docs/gpio_setup.md](docs/gpio_setup.md) |
| Ethernet 100M (E/WE) | работает | встроенный EPHY, патч ephy-init |
| Wi-Fi 6 + BT 5 (W/WE) | работает | [docs/wifi_setup.md](docs/wifi_setup.md) |
| USB gadget (ACM-консоль) | работает | [docs/usb_setup.md](docs/usb_setup.md) |
| Аудио (микрофон + динамик) | работает | [docs/audio_setup.md](docs/audio_setup.md) |
| TPU (0.5 TOPS INT8, BF16) | работает | [docs/tpu_sg2002.md](docs/tpu_sg2002.md) |
| RTC | работает | [docs/rtc_setup.md](docs/rtc_setup.md) |
| Watchdog | работает | [docs/watchdog_setup.md](docs/watchdog_setup.md) |
| Термосенсор | работает | [docs/thermal_setup.md](docs/thermal_setup.md) |
| LED, триггеры | работает | [docs/led_setup.md](docs/led_setup.md) |
| I2C, ADC | работает | [docs/i2c_setup.md](docs/i2c_setup.md), [docs/adc_setup.md](docs/adc_setup.md) |
| SARADC-карта пинов | справочник | [docs/sg2002_pin_map.md](docs/sg2002_pin_map.md) |

Дисплей (MIPI DSI), камера (ISP) и видеокодек (VPU) в mainline-стеке
пока не поддержаны, это закрытые или тяжёлые vendor-блоки.

## TPU

Инференс на встроенном TPU работает через форвард-порт vendor-драйвера
(`soph_tpu.ko`, собирается автоматически). В этом репозитории живёт
kernel-сторона: драйвер, DT-узел `cvitek,tpu`, ioctl-контракт
`CVITPU_GET_PADDR`. Userspace-стек (кросс-сборка рантайма, компиляция
моделей контейнером tpu-mlir, бенч-кит, полный пайплайн от ONNX до
запуска на плате) в этот репозиторий не входит.
Обзор блока TPU в [docs/tpu_sg2002.md](docs/tpu_sg2002.md). Якорные
цифры: mobilenet_v2 BF16 около 22 мс, yolov5s INT8 с INT8-вводом около
77 мс на 700 МГц.

## Лицензии

Собственная обвязка проекта под MIT (файл LICENSE). Каждый снапшот в
`src/` сохраняет лицензию своего upstream. Происхождение и статус
бинарных блобов описаны в [NOTICE.md](NOTICE.md).
