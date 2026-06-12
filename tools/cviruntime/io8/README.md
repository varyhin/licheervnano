# Приём io8: первая свёртка на TPU через INT8 I/O

Обобщённый приём оптимизации латентности CV-моделей на cv181x/SG2002 TPU,
выведенный на yolov5s (`../yolo/`) и подтверждённый на ultraface
(`build_ultraface.sh`). Память `tpu-io8-first-conv-on-tpu`.

## Суть

Когда модель компилируется в INT8, но с FP32 входом (дефолт `model_deploy
--quantize INT8`), tpu-mlir оставляет ПЕРВУЮ свёртку (стем) на CPU, где она
считается скалярно и доминирует в латентности. Компиляция с INT8 I/O
(`--quant_input --quant_output`) убирает входной quant-каст, и первая свёртка
уходит на TPU. Подавать на вход уже квантованный int8.

Это НЕ оптимизация кода рантайма (RVV и т.п.), а флаг компилятора. Найдено
прямым профилем (`MEASURE_TIME`), не теорией: прежняя гипотеза «узел это
fp32↔int8 касты I/O» была опровергнута (`../cast_bench.cpp`: каст 10-27нс/элем,
дёшев).

## Замеры (железо 2026-06-11, TPU 700, CPU 1050)

| модель | архитектура | fp32-I/O | io8 | ускорение | где был узел |
|---|---|---|---|---|---|
| yolov5s | anchor det | 448 мс | 77 мс | 5.8x | `model.0/conv` на CPU 370мс (82%) |
| ultraface | mobilenet-SSD (лица) | 67 мс | 2.3 мс | **29x** | `input247_Relu` на CPU 66мс (94%) |

ultraface даёт больший выигрыш: backbone легче, доля CPU-стема выше. Корректность
io8 == обычный int8 (граф тот же, отличается лишь вынесенный I/O-каст): на
ultraface argmax выходов scores/boxes совпали (8198/8202, 17498/17498).

## Рецепт

```
podman build -t tpu-mlir:local tools/tpu-mlir         # один раз
tools/cviruntime/io8/build_ultraface.sh                # -> int8 + io8 cvimodel + входы
tools/cviruntime/build.sh                              # рантайм + tpu_smoke
```

На плате (soph_tpu + CMA dma-heap):
```
LD_LIBRARY_PATH=lib bin/tpu_smoke ultraface_int8_io8.cvimodel ultraface_in_int8.bin  # io8, быстрый
LD_LIBRARY_PATH=lib bin/tpu_smoke ultraface_int8.cvimodel     ultraface_in_f32.bin   # fp32-I/O
```

## Профиль (поиск узла, воспроизводимо)

1. `../cast_bench.cpp` (кросс-собрать, прогнать на плате): малloc vs dma-heap,
   доказывает что каст дёшев и dma-heap кэшируемый.
2. `MEASURE_TIME`: раскомментировать `#define` в `src/common/program.cpp`
   клона cviruntime, пересобрать `.so`, подменить в ките. Печатает per-routine us
   (`[load]/[run]/[store]` TPU, `[to_cpu]/[cpu_run]+тензор` CPU). Так виден
   тяжёлый cpu_run первой conv в fp32-I/O и его исчезновение в io8.

## Как квантовать вход

INT8 I/O ждёт на входе int8, квантованный по threshold входного тензора из
калибровки: `int8 = clip(round(norm_input * 128 / threshold), -128, 127)`.
Для нормированного входа [0,1] (или [-1,1]) threshold ~1.0, то есть ~round(x*128).
threshold берётся `awk '/^<input_name> /{print $2}' <cali>`.

## Статус по моделям

- yolov5s: ВЫПОЛНЕНО (`../yolo/`)
- ultraface (mobilenet-SSD, лица): ВЫПОЛНЕНО (`build_ultraface.sh`)
- объектный mobilenet-ssd: ИСТОЧНИК ЗАБЛОКИРОВАН. TF-версия onnx model zoo
  (`ssd_mobilenet_v1_10`) не компилится (в графе Loop/NMS-постпроцессор +
  динамический uint8-вход), pytorch-ssd веса (qfgaohao) отдают HTTP 403. Чистого
  fp32-onnx объектного mobilenet-ssd под рукой нет. Варианты при необходимости:
  обрезать TF-граф до conv-выходов (трудоёмко, NHWC/Cast/Preprocessor) либо найти
  другой источник (mobilenetv2-ssdlite экспортом, нужен torch>=2.4, в контейнере
  2.1). ultraface это та же mobilenet-SSD архитектура, приём подтверждён.
