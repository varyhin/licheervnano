#!/usr/bin/env bash
# Компиляция saturating-моделей в INT8 cvimodel под cv181x. Запускается ВНУТРИ
# контейнера tpu-mlir (model_transform -> run_calibration -> model_deploy).
set -e
cd /work

declare -A SHAPE=(
  [conv1x1_c256_s64]="[[1,256,64,64]]"
  [conv1x1_c512_s64]="[[1,512,64,64]]"
  [conv3x3_c256_s64]="[[1,256,64,64]]"
  [conv3x3_c384_s48]="[[1,384,48,48]]"
  [gemm_m256_k1024_n1024]="[[256,1024]]"
)

for name in "${!SHAPE[@]}"; do
  echo "==================== $name ===================="
  model_transform.py \
    --model_name "$name" \
    --model_def "$name.onnx" \
    --input_shapes "${SHAPE[$name]}" \
    --mlir "$name.mlir" || { echo "TRANSFORM FAIL $name"; continue; }

  run_calibration.py "$name.mlir" \
    --data_list "${name}_cali_list.txt" \
    --input_num 4 \
    -o "${name}_cali_table" || { echo "CALI FAIL $name"; continue; }

  model_deploy.py \
    --mlir "$name.mlir" \
    --chip cv181x \
    --quantize INT8 \
    --calibration_table "${name}_cali_table" \
    --model "${name}_int8.cvimodel" || { echo "DEPLOY FAIL $name"; continue; }

  echo "OK $name -> ${name}_int8.cvimodel"
done
echo "ALL DONE"
