#!/usr/bin/env bash
# Обёртка для запуска инструментов tpu-mlir в контейнере (podman).
# Компилятор в контейнере, артефакты на хосте (текущий каталог -> /work).
#
# Один раз собрать образ:
#   podman build -t tpu-mlir:local tools/tpu-mlir
#
# Примеры:
#   tools/tpu-mlir/run.sh model_transform.py --model_name mobilenet_v2 \
#       --model_def mobilenet_v2.onnx --input_shapes [[1,3,224,224]] \
#       --mean 103.94,116.78,123.68 --scale 0.017,0.017,0.017 \
#       --pixel_format bgr --mlir mobilenet_v2.mlir
#   tools/tpu-mlir/run.sh model_deploy.py --mlir mobilenet_v2.mlir \
#       --chip cv181x --quantize BF16 --model mobilenet_v2_bf16.cvimodel
#
# Переопределить образ: TPU_MLIR_IMAGE=tpu-mlir:other tools/tpu-mlir/run.sh ...
set -euo pipefail
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
exec podman run --rm \
  -v "$PWD:/work:z" -w /work \
  "$IMAGE" "$@"
