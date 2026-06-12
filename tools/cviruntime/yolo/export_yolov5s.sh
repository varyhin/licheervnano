#!/usr/bin/env bash
# Экспорт yolov5s.onnx (классический anchor-based, 3-выходная голова) через
# контейнер tpu-mlir (в нём есть torch). git в контейнере нет, тянем исходники
# тарболом через python urllib. yolov5s.pt подтянется автоматически.
#
# ВАЖНО: нужен именно классический yolov5 (ultralytics/yolov5 repo, export.py),
# anchor-based, а НЕ ultralytics-пакет yolov5su (anchor-free). add_postprocess
# yolov5 ждёт anchor-based голову.
#
# Использование: tools/cviruntime/yolo/export_yolov5s.sh [workdir]  (default /tmp/yolo)
set -euo pipefail
WORK="${1:-/tmp/yolo}"
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
mkdir -p "$WORK"
podman run --rm --network=host -v "$WORK:/work:z" -w /work "$IMAGE" bash -c '
  set -e; cd /work
  if [ ! -d yolov5-7.0 ]; then
    python3 -c "import urllib.request as u; u.urlretrieve(\"https://codeload.github.com/ultralytics/yolov5/tar.gz/refs/tags/v7.0\",\"/tmp/y5.tgz\")"
    tar xzf /tmp/y5.tgz -C /work
  fi
  pip install --quiet --no-input IPython pandas pyyaml tqdm requests seaborn matplotlib 2>/dev/null || true
  cd yolov5-7.0
  python3 export.py --weights yolov5s.pt --include onnx --imgsz 640 --opset 12
  cp yolov5s.onnx /work/
'
echo "готово: $WORK/yolov5s.onnx"
