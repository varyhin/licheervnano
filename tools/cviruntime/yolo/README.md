# yolov5s на TPU cv181x (рецепт + находки)

Воспроизводимая компиляция yolov5s в cvimodel с фьюзом yolo-постпроцесса и
раннер `../tpu_yolo.cpp`. Подтверждено на железе 2026-06-03: боксы платы
построчно совпали с CMODEL (BF16 и INT8) на bus.jpg. Подробности латентности в
памяти `tpu-yolov5s-latency-io-cast-bottleneck`.

## Рецепт

```
podman build -t tpu-mlir:local tools/tpu-mlir         # один раз
tools/cviruntime/yolo/export_yolov5s.sh               # -> yolov5s.onnx
tools/cviruntime/yolo/build_yolov5s.sh                # -> bf16/int8 cvimodel + input_640_f32.bin
tools/cviruntime/build.sh                             # рантайм + tpu_yolo
```

На плате (soph_tpu + CMA dma-heap). Рекомендуется io8 (INT8 I/O), он в 5.8x
быстрее, см. раздел латентности:

```
LD_LIBRARY_PATH=lib bin/tpu_yolo yolov5s_int8_io8.cvimodel input_640_int8.bin   # 77мс
LD_LIBRARY_PATH=lib bin/tpu_yolo yolov5s_int8.cvimodel input_640_f32.bin        # 448мс
```

## Неочевидное (грабли)

- `--add_postprocess yolov5` ждёт 3 СЫРЫХ head-conv (255 кан = 3 anchors × 85),
  а НЕ склеенный `25200×85`. Дефолтный экспорт yolov5 даёт Detect-декод в графе.
  Фикс это `--output_names /model.24/m.{0,1,2}/Conv_output_0` (обрезка до голов).
  Без этого рантайм падает с `_bottoms.size() == 3`.
- Классический yolov5 (ultralytics/yolov5 repo, export.py), anchor-based. НЕ
  ultralytics-пакет yolov5su (anchor-free, для него другой постпроцесс).
- Выход `yolo_post` это `[1,1,200,7]`, но данные упакованы stride 6:
  `[x_c, y_c, w, h, cls, score]`, координаты нормированы [0,1] (×640 = пиксели).
- Пороги постпроцесса дефолт `nms=0.5 obj=0.5` дают дубли крупных анкоров
  (раздутая h, IoU с верным боксом ~0.28 < 0.5 не давится). Правка в mlir перед
  deploy: `nms_threshold=0.25` (CLI-опции у add_postprocess нет). Анкоры yolov5
  правильные, не причина.
- INT8-квант занижает скоры (bus 0.684 BF16 → <0.45 INT8, теряется). Нужна
  лучшая калибровка или mixed-precision головы.

## Латентность (железо 2026-06-11, CPU 1050, TPU 700 МГц)

Прямой профиль `MEASURE_TIME` libcviruntime дал ПОИМЁННУЮ раскладку. Прежняя
атрибуция «86% это касты I/O» ОПРОВЕРГНУТА (касты дёшевы, см. ниже).

| вариант | Forward | где время |
|---|---|---|
| INT8 fp32-I/O (`yolov5s_int8`) | 448 мс | `cpu_run model.0/conv` 370мс + tpu_run 65мс + yolo_post 13мс |
| INT8 int8-I/O (`yolov5s_int8_io8`) | **77 мс** | tpu_run 65мс + yolo_post 9мс (model.0 на TPU) |
| BF16 (`yolov5s_bf16`) | 381 мс | tpu_run 289мс + yolo_post 90мс |

Истинный узел это ПЕРВАЯ свёртка `model.0` (stem 3->32, k6 s2 на 640x640), которую
tpu-mlir в fp32-I/O INT8-компиляции оставляет НА CPU (скалярно, 370мс=82%).
`--quant_input --quant_output` убирает входной quant-каст -> model.0 уходит на
TPU -> 448->77мс (5.8x), корректность та же (боксы person ±0.01). Фикс
КОМПИЛЯТОРНЫЙ, без RVV рантайма и без рефлеша.

## Методика поиска узла (воспроизводимая)

1. `tools/cviruntime/cast_bench.cpp` (кросс-собрать `riscv64-linux-gnu-g++ -O2
   -march=rv64gc`, прогнать на плате): дифференцирует malloc vs dma-heap, мерит
   нс/элем каста. Показал каст 10-27нс/элем, dma-heap кэшируемый (B/A=1.0x) это
   «узел НЕ тут».
2. Профиль рантайма: раскомментировать `#define MEASURE_TIME` в
   `src/common/program.cpp` склонированного cviruntime, пересобрать `.so`
   (`cmake --build .../build/cviruntime --target cviruntime`), подменить в ките,
   прогнать. Печатает per-routine us: `[load]/[run]/[store]` TPU-секции,
   `[to_cpu]/[cpu_run]+имя_тензора` CPU-секции. Так нашёлся `model.0/conv` на CPU.

Замер mobilenet (smoke/bench/soak) и yolo это дорогие прогоны на железе, методику
держать сворачиваемой одной командой (см. память automate-and-save-test-methodology).
