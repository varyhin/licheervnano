#!/usr/bin/env bash
# Эталонная сверка компилятора tpu-mlir (контейнер tools/tpu-mlir).
#
# Генерирует референс-набор cvimodel и нормализованный манифест хешей.
# Применение: после ЛЮБОГО обновления контейнера/wheel компилятора прогнать
# скрипт и сравнить MANIFEST.norm.txt с зафиксированным манифестом
# (etalon_v1.28.1_manifest.txt рядом). Совпадение значит компилятор эмитит
# бит-в-бит то же самое и перевалидация моделей на железе не нужна.
# Методика и факты детерминизма в docs/tpu_setup.md, раздел «Детерминизм».
#
# Предусловия в $WORK/src/: mobilenet_v2.onnx, dog.jpg, yolov5s.onnx
# (см. tools/cviruntime/yolo/export_yolov5s.sh), coco128/ (датасет
# калибровки), yolov5-7.0/data/images/bus.jpg. Сеть не нужна.
#
# Использование: tools/tpu-mlir/gen_etalon.sh [workdir]   (default /tmp/tpu-etalon)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-/tmp/tpu-etalon}"
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
cd "$WORK"
RUN() { # RUN <workdir-под-$WORK> <bash-команды>
  podman run --rm -v "$WORK:/work:z" -w "/work/$1" "$IMAGE" bash -ec "$2"
}

echo "=== ENV ==="
{
  podman images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | grep tpu-mlir
  # head/grep НЕ снаружи podman run: ранний close stdout даёт broken pipe (126)
  podman run --rm "$IMAGE" bash -c 'pip show tpu_mlir | head -3; pip freeze'
} > ENV.txt
head -4 ENV.txt

echo "=== детерминизм BF16 (det1/det2): два прогона обязаны дать один норм-хеш ==="
for d in det1 det2; do
  rm -rf "determinism/$d"; mkdir -p "determinism/$d"
  cp src/mobilenet_v2.onnx "determinism/$d/"
  RUN "determinism/$d" "
    model_transform.py --model_name mobilenet_v2 --model_def mobilenet_v2.onnx \
      --input_shapes [[1,3,224,224]] --mean 103.94,116.78,123.68 \
      --scale 0.017,0.017,0.017 --pixel_format bgr --mlir mobilenet_v2.mlir
    model_deploy.py --mlir mobilenet_v2.mlir --chip cv181x --quantize BF16 \
      --model mobilenet_v2_bf16.cvimodel" > "determinism/$d/build.log" 2>&1
done

echo "=== mobilenet: transform + калибровка x2 + deploy BF16/INT8 ==="
rm -rf mobilenet; mkdir -p mobilenet
cp src/mobilenet_v2.onnx src/dog.jpg mobilenet/
RUN mobilenet "
  model_transform.py --model_name mobilenet_v2 --model_def mobilenet_v2.onnx \
    --input_shapes [[1,3,224,224]] --mean 103.94,116.78,123.68 \
    --scale 0.017,0.017,0.017 --pixel_format bgr \
    --test_input dog.jpg --test_result mobilenet_v2_top.npz --mlir mobilenet_v2.mlir
  run_calibration.py mobilenet_v2.mlir --dataset /work/src/coco128/images/train2017 \
    --input_num 100 -o mobilenet_v2_cali
  run_calibration.py mobilenet_v2.mlir --dataset /work/src/coco128/images/train2017 \
    --input_num 100 -o mobilenet_v2_cali_det2
  # сверка без комментариев: строка '# genetated time' меняется всегда
  diff <(grep -v '^#' mobilenet_v2_cali) <(grep -v '^#' mobilenet_v2_cali_det2) \
    && echo 'CALI DETERMINISTIC' || echo 'CALI NON-DETERMINISTIC'
  model_deploy.py --mlir mobilenet_v2.mlir --chip cv181x --quantize BF16 \
    --test_input mobilenet_v2_in_f32.npz --test_reference mobilenet_v2_top.npz \
    --model mobilenet_v2_bf16.cvimodel
  model_deploy.py --mlir mobilenet_v2.mlir --chip cv181x --quantize INT8 \
    --calibration_table mobilenet_v2_cali \
    --test_input mobilenet_v2_in_f32.npz --test_reference mobilenet_v2_top.npz \
    --model mobilenet_v2_int8.cvimodel" > mobilenet/build.log 2>&1
grep -E 'CALI (NON-)?DETERMINISTIC' mobilenet/build.log

echo "=== yolov5s (BF16+INT8+io8) ==="
rm -rf yolov5s; mkdir -p yolov5s
cp src/yolov5s.onnx yolov5s/
cp -r src/coco128 yolov5s/coco128
mkdir -p yolov5s/yolov5-7.0/data/images
cp src/yolov5-7.0/data/images/*.jpg yolov5s/yolov5-7.0/data/images/
"$SCRIPT_DIR/../cviruntime/yolo/build_yolov5s.sh" "$WORK/yolov5s" > yolov5s/build.log 2>&1

echo "=== MANIFEST.norm.txt (нормализованные хеши, сверять с эталонным) ==="
{
  python3 "$SCRIPT_DIR/cvimodel_norm.py" \
    determinism/det1/mobilenet_v2_bf16.cvimodel \
    determinism/det2/mobilenet_v2_bf16.cvimodel \
    mobilenet/mobilenet_v2_bf16.cvimodel \
    mobilenet/mobilenet_v2_int8.cvimodel \
    yolov5s/yolov5s_bf16.cvimodel \
    yolov5s/yolov5s_int8.cvimodel \
    yolov5s/yolov5s_int8_io8.cvimodel
  for t in mobilenet/mobilenet_v2_cali yolov5s/yolov5s_cali; do
    printf '%s  cali-noComments  %s\n' "$(grep -v '^#' $t | sha256sum | cut -d' ' -f1)" "$t"
  done
} | tee MANIFEST.norm.txt
find determinism mobilenet yolov5s -maxdepth 2 -type f \
  \( -name '*.cvimodel' -o -name '*cali*' -o -name '*.npz' -o -name '*.mlir' -o -name '*.bin' \) \
  -exec sha256sum {} + | sort -k2 > MANIFEST.sha256
echo "ETALON OK"
