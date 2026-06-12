# Saturating-модели для замера максимума TPU (cv181x)

Воспроизводимый рецепт compute-bound INT8-моделей (большие Conv/GEMM), чтобы
измерить ДОСТИЖИМЫЙ пик TPU на железе. mobilenet даёт лишь ~4% пика из-за
depthwise это здесь модели с высокой арифметической интенсивностью, держащие
MAC-массив занятым.

## Зачем

Паспортные 0.5/0.7/1.0 TOPS это расчётный пик (MAC × 2 × клок), не замер.
Эти модели позволяют замерить, сколько реально берётся, и эмпирически уточнить
число MAC/такт (true = effective_TOPS / (2 × клок)).

## Рецепт

```
mkdir -p /tmp/tpu-max && cp gen_models.py compile_all.sh /tmp/tpu-max/
cd /tmp/tpu-max
# 1) сгенерировать ONNX + калибровочные npz (в контейнере, есть onnx/numpy)
podman run --rm -v /tmp/tpu-max:/work:z -w /work tpu-mlir:local python3 gen_models.py
# 2) скомпилировать в INT8 cvimodel (transform -> calibration -> deploy)
podman run --rm -v /tmp/tpu-max:/work:z -w /work tpu-mlir:local bash compile_all.sh
```

На выходе `*_int8.cvimodel` + FLOPs в `*_final.mlir` (`module.FLOPs`).

## Свип

| Модель | Операция | MACs | FLOPs |
|---|---|---|---|
| conv1x1_c256_s64 | Conv 1×1, 256→256, 64×64 | 268M | 536870912 |
| conv1x1_c512_s64 | Conv 1×1, 512→512, 64×64 | 1.07G | 2147483648 |
| conv3x3_c256_s64 | Conv 3×3, 256→256, 64×64 | 2.42G | 4831838208 |
| conv3x3_c384_s48 | Conv 3×3, 384→384, 48×48 | 3.06G | 6115295232 |
| gemm_m256_k1024_n1024 | MatMul [256,1024]×[1024,1024] | 268M | 536870912 |

Conv 3×3 с большими каналами это самая высокая интенсивность это ближе всего к
пику. Замер на плате через `tpu_bench --flops <F> --clock-mhz <клок>` или
харнес `../tpu_maxtops.sh`.
