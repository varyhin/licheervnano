#!/usr/bin/env bash
# Воспроизводимая кросс-сборка userspace TPU-рантайма под Debian glibc riscv64
# для cv181x/SG2002. На выходе libcviruntime.so + libcvikernel.so + tpu_smoke.
#
# Зачем здесь: рантайм это source-available код sophgo (cviruntime/cvikernel/
# cvibuilder/cnpy), но prebuilt tpu-sdk-sg200x это musl+Xuantie на 5.10, под
# наш Debian glibc не грузится. Собираем из исходников стандартным rv64gc
# (vendor Xuantie-флаги не нужны, код portable) + мигрируем аллокатор с ION
# на dma-buf heaps (патч 0001).
#
# Совместимость версии: tpu-mlir эмитит cvimodel 1.4, эти SHA рантайма тоже 1.4.
#
# КЛЮЧЕВАЯ СВЯЗЬ С ЯДРОМ: патч 0001 берёт физ. адрес dmabuf ioctl'ом
# CVITPU_GET_PADDR из драйвера soph_tpu (pagemap не работает для dma-heap CMA).
# Драйвер ОБЯЗАН иметь этот ioctl (src/cvitek-tpu-vendor + patches/cvitek-tpu-vendor).
#
# Подтверждено на железе 2026-06-02: mobilenet_v2 BF16, Forward OK 22.77 ms.
#
# Host-зависимости (Debian): g++-riscv64-linux-gnu cmake ninja-build
#   flatbuffers-compiler libflatbuffers-dev git
#
# Использование: tools/cviruntime/build.sh [workdir]   (default /tmp/tpu-rt)
#   SOURCE=repo      исходники из снапшотов src/ этого репозитория (default)
#   SOURCE=upstream  клон официальных репозиториев на пины манифеста
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
WORK="${1:-/tmp/tpu-rt}"
PREFIX="$WORK/install"
BUILD="$WORK/build"
TC="$HERE/toolchain-debian-riscv64.cmake"
CROSS=riscv64-linux-gnu-
SOURCE="${SOURCE:-repo}"

# пины официальных upstream (дублируют manifest/sources.mk, сверять при бампе)
declare -A REPO_SHA=(
  [cviruntime]=ef8044988c2b4a5d491125d13e6f048b5f8a1389
  [cvikernel]=0b37e46607be203bf9d4d29995f6fa4bbab69435
  [cvibuilder]=4309f2a649fc7cfe7160389d52a81c469dbdd7bc
  [cnpy]=4e8810b1a8637695171ed346ce68f6984e585ef4
)
ZLIB_SHA=e3dc0a85b7032e98380dec011bc8f2c2ee0d8fca

mkdir -p "$WORK" "$PREFIX" "$BUILD"

fetch_src() { # name url sha
  local d="$WORK/$1"
  if [ "$SOURCE" = repo ]; then
    # свежая копия снапшота при каждом запуске (двойное наложение
    # патча исключено)
    rsync -a --delete --exclude=.git "$PROJ/src/$1/" "$d/"
  else
    [ -d "$d/.git" ] || git clone -q "$2" "$d"
    git -C "$d" fetch -q --depth 1 origin "$3" 2>/dev/null || git -C "$d" fetch -q origin
    git -C "$d" checkout -q "$3"
    git -C "$d" checkout -q -- .
  fi
}

echo "==> исходники ($SOURCE)"
fetch_src cviruntime https://github.com/sophgo/cviruntime.git "${REPO_SHA[cviruntime]}"
fetch_src cvikernel  https://github.com/sophgo/cvikernel.git  "${REPO_SHA[cvikernel]}"
fetch_src cvibuilder https://github.com/sophgo/cvibuilder.git "${REPO_SHA[cvibuilder]}"
fetch_src cnpy       https://github.com/sophgo/cnpy.git       "${REPO_SHA[cnpy]}"
fetch_src zlib       https://github.com/madler/zlib.git       "$ZLIB_SHA"

echo "==> патч cviruntime (ION->dma-heap + GET_PADDR)"
( cd "$WORK/cviruntime" && git apply "$HERE/0001-dma-heap-getpaddr.patch" )

echo "==> cvibuilder (host, генерит cvimodel headers через Debian flatc)"
cmake -S "$WORK/cvibuilder" -B "$BUILD/cvibuilder" -G Ninja \
  -DFLATBUFFERS_PATH=/usr -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$BUILD/cvibuilder" --target install

echo "==> cvikernel (riscv64, CHIP=cv181x)"
cmake -S "$WORK/cvikernel" -B "$BUILD/cvikernel" -G Ninja -DCHIP=cv181x \
  -DCMAKE_TOOLCHAIN_FILE="$TC" -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$BUILD/cvikernel" --target install

echo "==> zlib (riscv64)"
cmake -S "$WORK/zlib" -B "$BUILD/zlib" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TC" -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$BUILD/zlib" --target install

echo "==> cnpy (riscv64, явный zlib)"
cmake -S "$WORK/cnpy" -B "$BUILD/cnpy" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TC" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DZLIB_LIBRARY="$PREFIX/lib/libz.so" -DZLIB_INCLUDE_DIR="$PREFIX/include"
cmake --build "$BUILD/cnpy" --target install

echo "==> cviruntime (riscv64, CHIP=cv181x RUNTIME=SOC)"
cmake -S "$WORK/cviruntime" -B "$BUILD/cviruntime" -G Ninja \
  -DCHIP=cv181x -DRUNTIME=SOC -DCMAKE_TOOLCHAIN_FILE="$TC" \
  -DCVIKERNEL_PATH="$PREFIX" -DCVIBUILDER_PATH="$PREFIX" -DFLATBUFFERS_PATH=/usr \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DENABLE_PYRUNTIME=OFF
cmake --build "$BUILD/cviruntime" --target cviruntime cviruntime-static
cp "$BUILD/cviruntime"/src/soc/*/libcviruntime.so "$PREFIX/lib/"

# Профилировочный вариант libcviruntime (MEASURE_TIME): печатает per-routine us
# по слоям forward (`[load]/[run]/[store]` TPU, `[to_cpu]/[cpu_run]+тензор` CPU).
# Так найден узел латентности (первая conv на CPU, см. tools/cviruntime/io8/).
# Включается compile-флагом БЕЗ правки исходника (`#define MEASURE_TIME` в
# program.cpp остаётся закомментирован, макрос приходит из -D). default on,
# отключить TPU_MEASURE=0.
if [ "${TPU_MEASURE:-1}" = 1 ]; then
  echo "==> cviruntime measure-вариант (libcviruntime_measure.so, профиль латентности)"
  cmake -S "$WORK/cviruntime" -B "$BUILD/cviruntime_measure" -G Ninja \
    -DCHIP=cv181x -DRUNTIME=SOC -DCMAKE_TOOLCHAIN_FILE="$TC" \
    -DCVIKERNEL_PATH="$PREFIX" -DCVIBUILDER_PATH="$PREFIX" -DFLATBUFFERS_PATH=/usr \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DENABLE_PYRUNTIME=OFF \
    -DCMAKE_CXX_FLAGS="-DMEASURE_TIME"
  cmake --build "$BUILD/cviruntime_measure" --target cviruntime
  cp "$BUILD/cviruntime_measure"/src/soc/*/libcviruntime.so "$PREFIX/lib/libcviruntime_measure.so"
fi

echo "==> tpu_smoke + tpu_bench + tpu_yolo + tpu_soak"
mkdir -p "$PREFIX/bin"
# -Wall -Wextra -Werror на НАШИХ раннерах (наш код, ловит регрессии). Vendor
# cviruntime CMake остаётся БЕЗ -Werror (наш патч 0001 снял его намеренно:
# mainline-заголовки дают warnings в vendor-коде, чинить чужой код = против
# тонкого форка, см. docs/tpu_setup.md).
for runner in tpu_smoke tpu_bench tpu_yolo tpu_soak; do
  ${CROSS}g++ -march=rv64gc -mabi=lp64d -O2 -Wall -Wextra -Werror \
    -I"$WORK/cviruntime/include" "$HERE/$runner.cpp" -o "$PREFIX/bin/$runner" \
    -L"$PREFIX/lib" -lcviruntime -lcvikernel -lpthread -Wl,-rpath,'$ORIGIN/../lib'
done

echo "==> готово: $PREFIX/lib/{libcviruntime,libcvikernel}.so + $PREFIX/bin/{tpu_smoke,tpu_bench,tpu_yolo,tpu_soak}"
[ -f "$PREFIX/lib/libcviruntime_measure.so" ] && echo "    + libcviruntime_measure.so (профиль MEASURE_TIME)"
