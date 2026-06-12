# Манифест компонентов licheervnano.
#
# У каждого компонента два источника:
# - снапшот в src/<имя> внутри этого репозитория (источник по умолчанию,
#   сборка использует его как есть, сеть не нужна)
# - официальный upstream по пину (make refetch COMP=<имя> SOURCE=upstream
#   перекачивает дерево пина поверх src/<имя>; пустой вывод
#   git status --short --ignored -- src/<имя> после этого подтверждает
#   отсутствие дрейфа снапшота)
#
# Флаг --ignored обязателен: вложенные .gitignore снапшотов прячут файлы,
# которые upstream хранит в git (у u-boot таких 235, добавлены git add -f).
# Без --ignored дрейф по таким файлам невидим.
#
# Ядро linux в репозитории не хранится, его приносит make fetch-linux.
# Снапшот обязан быть бит-в-бит равен дереву upstream на пине
# (исключения перечислены в сообщении импорт-коммита компонента).

# Клонируется при сборке, в репо не хранится
URL_linux := https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
REF_linux := v6.18.29
PIN_linux := d31a849ff5011dad5c271b53819a0b279e367d68

# Хранятся в src/ как снапшоты
COMPONENTS := u-boot opensbi fiptool \
              licheerv-nano-build-vendor aic8800-vendor cvitek-tpu-vendor

URL_u-boot := https://source.denx.de/u-boot/u-boot.git
ALT_u-boot := https://github.com/u-boot/u-boot.git
REF_u-boot := v2025.10
PIN_u-boot := e50b1e8715011def8aff1588081a2649a2c6cd47

URL_opensbi := https://github.com/riscv-software-src/opensbi.git
REF_opensbi := v1.8.1
PIN_opensbi := 74434f255873d74e56cc50aa762d1caf24c099f8

URL_fiptool := https://github.com/sophgo/fiptool.git
PIN_fiptool := 7f59889c91f7d5d440d6a09aad0209f0aca3d09d

# Три извлечения из одного коммита sipeed/LicheeRV-Nano-Build
URL_licheerv-nano-build-vendor := https://github.com/sipeed/LicheeRV-Nano-Build.git
PIN_licheerv-nano-build-vendor := d4003f15b35d43ad4842f427050ab2bba0114fa5
SUBPATH_licheerv-nano-build-vendor := .gitignore README.md build fsbl
EXCLUDE_licheerv-nano-build-vendor := build/tools/common/ota_tool/utils/example/cvi_mipi_tx.ko

URL_aic8800-vendor := https://github.com/sipeed/LicheeRV-Nano-Build.git
PIN_aic8800-vendor := d4003f15b35d43ad4842f427050ab2bba0114fa5
SUBPATH_aic8800-vendor := osdrv/extdrv/wireless/aic8800

URL_cvitek-tpu-vendor := https://github.com/sipeed/LicheeRV-Nano-Build.git
PIN_cvitek-tpu-vendor := d4003f15b35d43ad4842f427050ab2bba0114fa5
SUBPATH_cvitek-tpu-vendor := osdrv/interdrv/v2/tpu

# Userspace TPU-стек (cviruntime, cvikernel, cvibuilder, cnpy, zlib)
# вынесен в отдельный репозиторий licheervnano-tpu-sdk-sg2002.
