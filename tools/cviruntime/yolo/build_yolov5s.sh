#!/usr/bin/env bash
# Компиляция yolov5s под cv181x в BF16 + INT8 cvimodel с фьюзом yolo-постпроцесса.
# Шаги: обрезка графа до 3 head-conv -> add_postprocess yolov5 -> тюнинг порогов
# -> калибровка coco128 -> deploy BF16 + INT8. Плюс препроцесс bus.jpg в
# input_640_f32.bin (один вход на обе модели, INT8 квантует внутри).
#
# Предусловие: yolov5s.onnx (см. export_yolov5s.sh) в workdir.
# Использование: tools/cviruntime/yolo/build_yolov5s.sh [workdir]  (default /tmp/yolo)
set -euo pipefail
WORK="${1:-/tmp/yolo}"
IMAGE="${TPU_MLIR_IMAGE:-tpu-mlir:local}"
# 3 сырых выхода головы (255 кан = 3 anchors x 85). add_postprocess yolov5 ждёт
# ИХ, а не склеенный 25200x85 (дефолтный экспорт даёт декод в графе).
HEADS=/model.24/m.0/Conv_output_0,/model.24/m.1/Conv_output_0,/model.24/m.2/Conv_output_0
podman run --rm --network=host -v "$WORK:/work:z" -w /work "$IMAGE" bash -c "
  set -e; cd /work
  [ -f yolov5s.onnx ] || { echo 'нет yolov5s.onnx, сначала export_yolov5s.sh'; exit 1; }
  if [ ! -d coco128/images ]; then
    # github releases (ultralytics.com/assets отдаёт HTTP 308, urllib не идёт)
    python3 -c 'import urllib.request as u; u.urlretrieve(\"https://github.com/ultralytics/yolov5/releases/download/v1.0/coco128.zip\",\"/tmp/c.zip\")'
    python3 -c 'import zipfile; zipfile.ZipFile(\"/tmp/c.zip\").extractall(\"/work\")'
  fi
  # transform: обрезка до 3 голов + фьюз постпроцесса + препроцесс bus.jpg
  model_transform.py --model_name yolov5s --model_def yolov5s.onnx \
    --input_shapes [[1,3,640,640]] --mean 0,0,0 --scale 0.0039216,0.0039216,0.0039216 \
    --pixel_format rgb --output_names $HEADS --add_postprocess yolov5 \
    --test_input yolov5-7.0/data/images/bus.jpg --test_result yolov5s_top.npz --mlir yolov5s.mlir
  # ТЮНИНГ порога NMS в mlir (CLI у add_postprocess нет): дефолт nms=0.5 даёт
  # дубли крупных анкоров (раздутая h, IoU с верным боксом ~0.28 не давится).
  sed -i 's/nms_threshold = 5.000000e-01/nms_threshold = 2.500000e-01/' yolov5s.mlir
  # вход для платы (fp32, [0,255], NCHW), один на обе модели
  python3 -c 'import numpy as np; np.ascontiguousarray(np.load(\"yolov5s_in_f32.npz\")[\"images\"].astype(\"<f4\")).tofile(\"input_640_f32.bin\")'
  # калибровка INT8 на coco128
  run_calibration.py yolov5s.mlir --dataset /work/coco128/images/train2017 --input_num 100 -o yolov5s_cali
  # deploy
  model_deploy.py --mlir yolov5s.mlir --chip cv181x --quantize BF16 --model yolov5s_bf16.cvimodel
  model_deploy.py --mlir yolov5s.mlir --chip cv181x --quantize INT8 --calibration_table yolov5s_cali --model yolov5s_int8.cvimodel
  # io8: INT8 I/O. КРИТИЧНО для латентности (железо 2026-06-11): с fp32-входом
  # tpu-mlir держит первую conv model.0 на CPU (370мс=82%); quant_input её
  # отдаёт TPU -> yolov5s 448->77мс (5.8x), корректность та же. См. память
  # tpu-yolov5s-latency-io-cast-bottleneck. Профиль узла: cast_bench + MEASURE_TIME.
  model_deploy.py --mlir yolov5s.mlir --chip cv181x --quantize INT8 \
    --calibration_table yolov5s_cali --quant_input --quant_output \
    --model yolov5s_int8_io8.cvimodel
  # квантованный int8-вход для io8: вход [0,1] (scale 1/255), квант по threshold
  # входного тензора из калибровки (для yolo ~1.0 => round(x*128)), clip int8
  T=\$(awk '/^images /{print \$2; exit}' yolov5s_cali)
  python3 -c \"import numpy as np; x=np.load('yolov5s_in_f32.npz')['images'].astype('f4'); np.clip(np.rint(x*128.0/float('\$T')),-128,127).astype(np.int8).tofile('input_640_int8.bin')\"
"
echo "готово: $WORK/yolov5s_{bf16,int8,int8_io8}.cvimodel + input_640_f32.bin + input_640_int8.bin"
echo "на плате (быстрый io8, рекоменд.): bin/tpu_yolo yolov5s_int8_io8.cvimodel input_640_int8.bin"
echo "на плате (fp32 I/O, медленный):    bin/tpu_yolo yolov5s_int8.cvimodel input_640_f32.bin"
