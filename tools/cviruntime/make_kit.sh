#!/usr/bin/env bash
# Одна команда: регенерация всего TPU-тест-кита из исходников.
# Собирает рантайм+раннеры, генерит и компилит saturating-модели (INT8 fp32-IO
# и INT8 io8) через контейнер tpu-mlir, собирает самодостаточный tpu-kit.tar.gz
# (bin, lib, models, харнес, set_tpu_clk, run_900, README) для запуска на плате.
#
# Воспроизводит методику замера 2026-06-03 (см. docs/tpu_benchmark_methodology.md).
#
# Предусловия (хост): тулчейн как в build.sh + контейнер tpu-mlir:
#   podman build -t tpu-mlir:local tools/tpu-mlir
#
# Использование: tools/cviruntime/make_kit.sh [workdir] [out.tar.gz]
#   MODELS_DIR=<dir> для mobilenet_v2_bf16.cvimodel + input_dog.bin (опц.,
#   gate корректности разгона). По умолчанию /tmp/tpu-models. Если нет, кит
#   соберётся без mobilenet (run_900 не отработает, но свип TOPS будет).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SAT="$HERE/saturating"
WORK="${1:-/tmp/tpu-kit-build}"
OUT="${2:-$WORK/tpu-kit.tar.gz}"
MODELS_DIR="${MODELS_DIR:-/tmp/tpu-models}"
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
KIT="$WORK/tpu-kit"

# FLOPs saturating-моделей (из tpu-mlir module.FLOPs, для справки/проверки)
mkdir -p "$WORK"

echo "==> [1/4] рантайм + раннеры (build.sh)"
bash "$HERE/build.sh" "$WORK/rt"
RTLIB="$WORK/rt/install/lib"
RTBIN="$WORK/rt/install/bin"

echo "==> [2/4] saturating-модели (gen + compile int8 + io8) в контейнере"
MWORK="$WORK/models-src"
mkdir -p "$MWORK"
cp "$SAT/gen_models.py" "$SAT/compile_all.sh" "$SAT/compile_io8.sh" "$MWORK/"
podman run --rm -v "$MWORK:/work:z" -w /work "$IMAGE" python3 gen_models.py
podman run --rm -v "$MWORK:/work:z" -w /work "$IMAGE" bash compile_all.sh
podman run --rm -v "$MWORK:/work:z" -w /work "$IMAGE" bash compile_io8.sh

echo "==> [3/4] сборка кита"
rm -rf "$KIT"
mkdir -p "$KIT/bin" "$KIT/lib" "$KIT/models"
cp "$RTBIN/tpu_bench" "$RTBIN/tpu_smoke" "$RTBIN/tpu_soak" "$KIT/bin/"
cp "$RTLIB/libcviruntime.so" "$RTLIB/libcvikernel.so" "$KIT/lib/"
# профилировочный вариант (MEASURE_TIME), если собран build.sh (TPU_MEASURE=1)
[ -f "$RTLIB/libcviruntime_measure.so" ] && cp "$RTLIB/libcviruntime_measure.so" "$KIT/lib/"
cp "$MWORK"/*_int8.cvimodel "$MWORK"/*_io8.cvimodel "$KIT/models/"
cp "$HERE/tpu_maxtops.sh" "$HERE/set_tpu_clk.py" "$HERE/run_900.sh" "$KIT/"
cp "$HERE/kit_README.txt" "$KIT/README.txt"
chmod +x "$KIT/tpu_maxtops.sh" "$KIT/run_900.sh" "$KIT/bin/"*

# опционально mobilenet + реальный вход (gate корректности разгона)
if [ -f "$MODELS_DIR/mobilenet_v2_bf16.cvimodel" ]; then
  cp "$MODELS_DIR/mobilenet_v2_bf16.cvimodel" "$KIT/models/"
  if [ -f "$MODELS_DIR/mobilenet_v2_in_f32.npz" ]; then
    podman run --rm -v "$MODELS_DIR:/in:z" -v "$KIT:/out:z" "$IMAGE" python3 -c \
      'import numpy as np; np.ascontiguousarray(np.load("/in/mobilenet_v2_in_f32.npz")["input"].astype("<f4")).tofile("/out/input_dog.bin")'
    echo "    + mobilenet_v2_bf16 + input_dog.bin (gate корректности)"
  fi
else
  echo "    ! mobilenet нет в $MODELS_DIR, кит без gate корректности разгона"
fi

echo "==> [4/4] архив"
( cd "$WORK" && tar czf "$OUT" tpu-kit )
echo "готово: $OUT"
echo "  sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "  на плате: tar xzf $(basename "$OUT") && cd tpu-kit && ./tpu_maxtops.sh"
