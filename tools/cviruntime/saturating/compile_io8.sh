#!/usr/bin/env bash
# Передеплой saturating-моделей с INT8 I/O (--quant_input/--quant_output):
# убирает CPU-конверсию fp32<->int8 и режет I/O вчетверо. mlir+cali уже есть.
set -e
cd /work
for name in conv1x1_c256_s64 conv1x1_c512_s64 conv3x3_c256_s64 conv3x3_c384_s48 gemm_m256_k1024_n1024; do
  echo "==== $name (io8) ===="
  model_deploy.py \
    --mlir "$name.mlir" \
    --chip cv181x \
    --quantize INT8 \
    --calibration_table "${name}_cali_table" \
    --quant_input --quant_output \
    --model "${name}_io8.cvimodel" || { echo "FAIL $name"; continue; }
  echo "OK ${name}_io8.cvimodel"
done
echo ALL DONE
