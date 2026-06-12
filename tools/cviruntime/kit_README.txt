TPU kit (LicheeRV Nano, SG2002 / cv181x) — единый самодостаточный архив
=======================================================================

Всё для замера TPU и разгона на плате в одном каталоге. Распаковать и
запускать ОТСЮДА (bin/ lib/ models/ и скрипты должны быть рядом).

Предусловия на плате: soph_tpu загружен (/dev/cvi-tpu0), CMA dma-heap
(/dev/dma_heap/...), FSBL perf (TPU 700 МГц).

Состав
------
bin/tpu_bench, bin/tpu_smoke   раннеры (riscv64 glibc)
bin/tpu_soak                   многочасовой soak (утечки/деградация/троттлинг)
lib/*.so                       рантайм cviruntime+cvikernel
lib/libcviruntime_measure.so   профиль MEASURE_TIME (per-routine us по слоям)
models/*_io8.cvimodel          saturating INT8 с INT8 I/O (быстрые, для TOPS)
models/*_int8.cvimodel         те же с FP32 I/O (медленные, для контраста)
models/mobilenet_v2_bf16       реальная сеть (для проверки стабильности)
tpu_maxtops.sh                 свип + детект клока + сводка максимума
set_tpu_clk.py                 смена клока TPU через /dev/mem (обратимо)
input_dog.bin                  вход для mobilenet (стабильный эталон argmax)
run_900.sh                     разгон 700->900 с гейтом стабильности

Установка
---------
  tar xzf tpu-kit.tar.gz
  cd tpu-kit

Что и в какой последовательности
--------------------------------
1) Замер максимума на штатных 700 МГц:
     ./tpu_maxtops.sh
   Печатает таблицу fwd_p50/eff_TOPS/%peak по io8-моделям + строку МАКСИМУМ.

2) Разгон до 900 МГц и замер (одной командой, с откатом при нестабильности):
     ./run_900.sh
   Снимает argmax на 700 как эталон, разгоняет, требует тот же argmax на 900,
   при совпадении гонит свип на 900, в конце откатывает на 700.

   Вручную по шагам:
     LD_LIBRARY_PATH=lib bin/tpu_smoke models/mobilenet_v2_bf16.cvimodel input_dog.bin  # запомнить argmax@700
     python3 set_tpu_clk.py 900
     LD_LIBRARY_PATH=lib bin/tpu_smoke models/mobilenet_v2_bf16.cvimodel input_dog.bin  # должен быть тот же argmax
     CLK_MHZ=900 ./tpu_maxtops.sh
     python3 set_tpu_clk.py revert

3) Один прогон любой модели вручную:
     LD_LIBRARY_PATH=lib bin/tpu_bench models/conv3x3_c384_s48_io8.cvimodel \
         -n 100 --flops 6115295232 --clock-mhz 700

4) Soak (стабильность, тысячи forward, лог метрик по времени):
     LD_LIBRARY_PATH=lib bin/tpu_soak models/mobilenet_v2_bf16.cvimodel \
         input_dog.bin --duration 14400 --report-sec 60 --csv soak.csv
   Гонит до --duration секунд (или --iters N, или Ctrl-C). Каждые 60с строка:
   p50/p99 окна, ΔRSS (утечка памяти), Δfd (утечка дескрипторов), temp
   (троттлинг), mism (дрейф argmax). В конце сводка + verdict. Запускать в
   фоне/nohup, следить tail -f soak.csv. mismatches>0 или растущий RSS/fd это
   красный флаг.

   Multi-model round-robin (варьирование РАЗМЕРОВ буферов, тест когерентности
   кеша на разных размерах): передать 2+ моделей, soak чередует их по кругу.
   argmax дрейф ИМЕННО одной модели в сводке = stale-cache на её размере.
     LD_LIBRARY_PATH=lib bin/tpu_soak \
       models/mobilenet_v2_bf16.cvimodel,input_dog.bin \
       models/conv1x1_c256_s64_io8.cvimodel \
       models/conv3x3_c384_s48_io8.cvimodel \
       models/gemm_m256_k1024_n1024_io8.cvimodel \
       --duration 3600 --report-sec 60 --csv soak_multi.csv
   io8-модели без input берут ramp (для тайминга/когерентности значения не важны).
   Финальная сводка печатает per-model iters/in0-размер/argmax/mism.

5) Профиль латентности по слоям (где время: TPU vs CPU). Подменить рантайм на
   measure-вариант, прогнать любой раннер, вернуть обычный:
     cp lib/libcviruntime.so lib/libcviruntime.so.orig
     cp lib/libcviruntime_measure.so lib/libcviruntime.so
     LD_LIBRARY_PATH=lib bin/tpu_smoke models/mobilenet_v2_bf16.cvimodel input_dog.bin
     cp lib/libcviruntime.so.orig lib/libcviruntime.so
   Печатает PERF-строки: [load]/[run]/[store] это TPU-секции,
   [to_cpu]/[cpu_run]+тензор это CPU-секции. Тяжёлый cpu_run первой conv в
   INT8 fp32-I/O это узел, лечится io8 (--quant_input, см. tools/cviruntime/io8/).

Заметки
-------
- argmax абсолютный класс НЕ важен для разгона, важна стабильность (тот же
  класс на 700 и 900). Эталон 258 из прошлых сессий был от другого препроцесса.
- clk_summary после разгона показывает старое 700 (framework не знает о прямой
  записи), поэтому харнес на 900 запускать с CLK_MHZ=900.
- Напряжение не трогается. Перезагрузка возвращает 700 (FSBL).
- TPU_LOG_* уходят в syslog (journalctl, facility local6).
- INT8 I/O (io8) обязателен для throughput: FP32 I/O даёт ~95x оверхед на
  CPU-конверсии. Замер 2026-06-03: io8 максимум 0.34 TOPS (48% от 0.7 @700).
