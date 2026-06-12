#!/usr/bin/env bash
# Воспроизводимая компиляция ultraface (version-RFB-320, mobilenet-backbone SSD
# face detector) под cv181x в ДВУХ вариантах для демонстрации приёма io8:
#   ultraface_int8.cvimodel      INT8 с FP32 I/O   (первая conv остаётся на CPU)
#   ultraface_int8_io8.cvimodel  INT8 с INT8 I/O   (первая conv уходит на TPU)
# Плюс входы под оба (f32 и квантованный int8).
#
# Подтверждено на железе 2026-06-11 (см. README.md рядом, память
# tpu-io8-first-conv-on-tpu): fp32-I/O 67мс (первый блок input247_Relu на CPU
# 66мс=94%), io8 2.3мс это 29x. Приём тот же, что у yolov5s (build_yolov5s.sh).
#
# Предусловие: контейнер tpu-mlir (podman build -t tpu-mlir:local tools/tpu-mlir).
# Использование: tools/cviruntime/io8/build_ultraface.sh [workdir]  (default /tmp/ultraface)
set -euo pipefail
WORK="${1:-/tmp/ultraface}"
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
RUN="$(cd "$(dirname "$0")/../.." && pwd)/tpu-mlir/run.sh"
mkdir -p "$WORK"

# onnx (onnx model zoo, LFS media)
[ -f "$WORK/ultraface.onnx" ] || curl -sL --max-time 120 -o "$WORK/ultraface.onnx" \
  "https://media.githubusercontent.com/media/onnx/models/main/validated/vision/body_analysis/ultraface/models/version-RFB-320.onnx"

podman run --rm --network=host -v "$WORK:/work:z" -w /work "$IMAGE" bash -c "
  set -e; cd /work
  # калибровочная выборка. coco128 это НЕ лица (для face-точности взять WIDER),
  # но для замера латентности/профиля и сверки io8==int8 достаточно.
  if [ ! -d coco128/images ]; then
    python3 -c 'import urllib.request as u; u.urlretrieve(\"https://github.com/ultralytics/yolov5/releases/download/v1.0/coco128.zip\",\"/tmp/c.zip\")'
    python3 -c 'import zipfile; zipfile.ZipFile(\"/tmp/c.zip\").extractall(\"/work\")'
    # любая картинка как test_input
    cp \$(ls coco128/images/train2017/*.jpg | head -1) sample.jpg
  fi
  # препроцесс ultraface: (x-127)/128, RGB; вход фикс [1,3,240,320]
  model_transform.py --model_name ultraface --model_def ultraface.onnx \
    --input_shapes [[1,3,240,320]] --mean 127,127,127 \
    --scale 0.0078125,0.0078125,0.0078125 --pixel_format rgb \
    --test_input sample.jpg --test_result ultraface_top.npz --mlir ultraface.mlir
  run_calibration.py ultraface.mlir --dataset coco128/images/train2017 --input_num 80 -o ultraface_cali
  # вариант A: INT8 FP32-I/O (первая conv на CPU)
  model_deploy.py --mlir ultraface.mlir --chip cv181x --quantize INT8 \
    --calibration_table ultraface_cali --model ultraface_int8.cvimodel
  # вариант B: INT8 I/O (первая conv на TPU) это приём io8
  model_deploy.py --mlir ultraface.mlir --chip cv181x --quantize INT8 \
    --calibration_table ultraface_cali --quant_input --quant_output \
    --model ultraface_int8_io8.cvimodel
  # входы под оба: f32 (для int8-модели) и квантованный int8 (для io8)
  T=\$(awk '/^input /{print \$2; exit}' ultraface_cali)
  python3 -c \"import numpy as np; x=np.load('ultraface_in_f32.npz')['input'].astype('f4'); np.ascontiguousarray(x).tofile('ultraface_in_f32.bin'); np.clip(np.rint(x*128.0/float('\$T')),-128,127).astype(np.int8).tofile('ultraface_in_int8.bin')\"
"
echo "готово: $WORK/ultraface_int8{,_io8}.cvimodel + ultraface_in_{f32,int8}.bin"
echo "на плате (io8, быстрый): bin/tpu_smoke ultraface_int8_io8.cvimodel ultraface_in_int8.bin"
echo "на плате (fp32-I/O):     bin/tpu_smoke ultraface_int8.cvimodel ultraface_in_f32.bin"
