# cviruntime (userspace TPU-рантайм) под Debian glibc riscv64

Воспроизводимая сборка userspace-стека инференса TPU cv181x/SG2002 из
исходников sophgo под наш Debian glibc riscv64. На выходе `libcviruntime.so`
+ `libcvikernel.so` + `tpu_smoke` (минимальный раннер датапаса).

Подтверждено на железе 2026-06-02: `mobilenet_v2` BF16, `Forward OK 22.77 ms`,
выход 1000 классов живой. Полный тракт runtime → dma-heap → ядерный
`GET_PADDR` → submit → `soph_tpu` → TPU → результат.

## Файлы

- `build.sh` это клонирует cviruntime/cvikernel/cvibuilder/cnpy/zlib на пины
  SHA, применяет патч, кросс-собирает. Host-deps в шапке скрипта.
- `0001-dma-heap-getpaddr.patch` это наши правки cviruntime:
  - аллокатор ION → dma-buf CMA heap (`cvi_device_mem.cpp`)
  - физ. адрес dmabuf через ЯДЕРНЫЙ ioctl `CVITPU_GET_PADDR` (pagemap НЕ
    работает для dma-heap CMA mmap, подтверждено на железе)
  - снят `-Werror` (mainline-заголовки дают посторонние warning'и)
- `toolchain-debian-riscv64.cmake` это Debian-кросс, стандартный `rv64gc`
  (vendor Xuantie-флаги не нужны, код portable).
- `tpu_smoke.cpp` это раннер: load cvimodel → CVI_NN_Forward → argmax+время.
- `tpu_bench.cpp` это раннер замера: N прогонов forward (плюс прогрев),
  латентность p50/p90/p95/p99/min/max/mean/stddev, throughput fps, разбивка
  фаз CPU-pre (заливка входа) / TPU-fwd / CPU-post (argmax-скан). Замер это
  wall-clock вокруг фаз. Внутренний PMU рантайма (per-layer TPU-циклы) идёт в
  syslog отдельно, на high-level API его нет. Сравнение TPU vs чистый CPU это
  отдельный прогон onnxruntime/скаляра на C906 на той же модели.
- `tpu_maxtops.sh` это on-board харнес: детект клока TPU + свип saturating-
  моделей через `tpu_bench` + сводка достижимого максимума (nameplate vs
  effective). Замер 2026-06-03: 0.34 TOPS на conv3x3 INT8 = 48% от 0.7 @700 МГц.
- `saturating/` это рецепт compute-bound моделей (Conv/GEMM, INT8) для замера
  пика: `gen_models.py` (ONNX) + `compile_all.sh` (контейнер tpu-mlir -> cvimodel).
- `set_tpu_clk.py` это смена клока TPU через `/dev/mem` (мукс `clk_tpu`,
  обратимо). Разгон 700->900 (mipimpll) проверен на железе: НЕстабилен на 0.96В
  (argmax 904->0), 700 это потолок без поднятия напряжения. Делает ровно то, что
  clk-framework (read-modify-write мукса/делителя REG_DIV_CLK_TPU).

## Связь с ядром (ОБЯЗАТЕЛЬНО)

Рантайм берёт физ. адрес dmabuf ioctl'ом `CVITPU_GET_PADDR` у драйвера
`soph_tpu`. Драйвер обязан иметь этот ioctl (`src/cvitek-tpu-vendor` +
`patches/cvitek-tpu-vendor/`). UAPI-определение должно совпадать в обоих
(`cvi_tpu_ioctl.h` ядра и `bm_npu_ioctl.h` рантайма): `_IOWR('p', 0x0D, ...)`
+ `struct cvi_dmabuf_paddr_arg { int fd; unsigned long long paddr; }`.

## Сборка и запуск

```
tools/cviruntime/build.sh            # -> /tmp/tpu-rt/install/{lib,bin}
```

Модель компилится контейнером `tools/tpu-mlir/` (cvimodel 1.4 = этот рантайм).
На плате (нужны soph_tpu загружен, CMA dma-heap, см. docs/tpu_setup.md):

```
LD_LIBRARY_PATH=<dir>/lib <dir>/bin/tpu_smoke model.cvimodel [input.bin]
LD_LIBRARY_PATH=<dir>/lib <dir>/bin/tpu_bench model.cvimodel [input.bin] [-n RUNS] [-w WARMUP] [--csv FILE]
```

`tpu_bench` по умолчанию это 50 прогонов плюс 5 прогревов. Флаг `--csv`
снимает per-итерационные времена (iter,pre_ms,fwd_ms,post_ms) для офлайн
разбора. Код возврата 7 если argmax разошёлся между итерациями (сигнал
некорректности под нагрузкой).

TPU_LOG_* уходят в syslog (`journalctl`, facility local6). Для отладки на
stdout временно закомментировать `#define LOG_TOWARD_SYSLOG` в
`include/cvitpu_debug.h`.
