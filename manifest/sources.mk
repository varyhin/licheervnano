# Манифест компонентов licheervnano.
#
# У каждого компонента два источника:
# - снапшот в src/<имя> внутри этого репозитория (источник по умолчанию,
#   сборка использует его как есть, сеть не нужна)
# - официальный upstream по пину (make refetch COMP=<имя> SOURCE=upstream
#   перекачивает дерево пина поверх src/<имя>; пустой git diff после этого
#   подтверждает отсутствие дрейфа снапшота)
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
              licheerv-nano-build-vendor aic8800-vendor cvitek-tpu-vendor \
              cviruntime cvikernel cvibuilder cnpy zlib

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

URL_cviruntime := https://github.com/sophgo/cviruntime.git
PIN_cviruntime := ef8044988c2b4a5d491125d13e6f048b5f8a1389

URL_cvikernel := https://github.com/sophgo/cvikernel.git
PIN_cvikernel := 0b37e46607be203bf9d4d29995f6fa4bbab69435

URL_cvibuilder := https://github.com/sophgo/cvibuilder.git
PIN_cvibuilder := 4309f2a649fc7cfe7160389d52a81c469dbdd7bc

URL_cnpy := https://github.com/sophgo/cnpy.git
PIN_cnpy := 4e8810b1a8637695171ed346ce68f6984e585ef4

URL_zlib := https://github.com/madler/zlib.git
PIN_zlib := e3dc0a85b7032e98380dec011bc8f2c2ee0d8fca
