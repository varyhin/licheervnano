// tpu_bench это раннер замера производительности TPU-датапаса cv181x/SG2002.
// Гонит CVI_NN_Forward N раз (плюс W прогревов), считает латентность forward
// p50/p90/p95/p99/min/max/mean/stddev, throughput fps и разбивку по фазам
// CPU-pre (заливка входа) / TPU-fwd (датапас) / CPU-post (argmax-скан).
// Вход и API те же, что у tpu_smoke (load cvimodel, raw input через argv или
// детерминированный ramp).
//
// Замер это wall-clock CLOCK_MONOTONIC вокруг каждой фазы. Внутренний PMU
// рантайма (ENABLE_PMU) пишет per-layer TPU-циклы в syslog отдельно, на
// high-level CVI_NN_ API его нет, здесь не дублируем. Сравнение TPU vs чистый
// CPU делается отдельным прогоном (onnxruntime/скаляр на C906 на той же
// модели), этот раннер даёт число TPU-стороны для сравнения.
//
// argmax выхода фиксируется на каждой итерации, расхождение считается это
// дешёвый сигнал корректности под нагрузкой (мини-soak), полный soak отдельно.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cmath>
#include <vector>
#include <algorithm>
#include "cviruntime.h"

#ifndef CVI_RC_SUCCESS
#define CVI_RC_SUCCESS 0
#endif

// Оценка пиковой производительности (nameplate). MAC-массив TIU cv181x по
// исходникам cvikernel это NPU_NUM=8 x EU_NUM=16, но conv-движок за такт
// делает больше, и публичная линейка 0.5 TOPS@500МГц, 1.0 TOPS@1ГГц сходится
// при ~512 INT8 MAC/такт (1024 оп/такт). Значение можно поправить, если
// появятся точные данные. nameplate TOPS = 2 x MAC_PER_CYCLE x clock.
#define MAC_PER_CYCLE 512

static double now_ms() {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static float get_elem(CVI_TENSOR *t, size_t i) {
  void *p = CVI_NN_TensorPtr(t);
  switch (t->fmt) {
  case CVI_FMT_FP32:  return ((float *)p)[i];
  case CVI_FMT_INT8:  return (((int8_t *)p)[i]  - t->zero_point) * t->qscale;
  case CVI_FMT_UINT8: return (((uint8_t *)p)[i] - t->zero_point) * t->qscale;
  case CVI_FMT_INT16: return ((int16_t *)p)[i];
  case CVI_FMT_BF16: {
    uint32_t u = (uint32_t)((uint16_t *)p)[i] << 16; float f; memcpy(&f, &u, 4); return f;
  }
  default: return (float)((uint8_t *)p)[i];
  }
}

// argmax по выходному тензору (для сигнала корректности под нагрузкой)
static size_t argmax(CVI_TENSOR *t) {
  size_t c = CVI_NN_TensorCount(t);
  if (!c) return 0;
  size_t best = 0; float bv = get_elem(t, 0);
  for (size_t j = 1; j < c; j++) {
    float v = get_elem(t, j);
    if (v > bv) { bv = v; best = j; }
  }
  return best;
}

// nearest-rank перцентиль по возрастающе отсортированному вектору
static double pct(const std::vector<double> &s, double p) {
  if (s.empty()) return 0.0;
  long idx = (long)std::ceil(p / 100.0 * (double)s.size()) - 1;
  if (idx < 0) idx = 0;
  if (idx >= (long)s.size()) idx = (long)s.size() - 1;
  return s[idx];
}

static double mean_of(const std::vector<double> &v) {
  double s = 0; for (double x : v) s += x; return v.empty() ? 0.0 : s / v.size();
}

static double stddev_of(const std::vector<double> &v, double m) {
  if (v.size() < 2) return 0.0;
  double s = 0; for (double x : v) s += (x - m) * (x - m);
  return std::sqrt(s / (v.size() - 1));
}

int main(int argc, char **argv) {
  const char *model_file = nullptr;
  const char *input_file = nullptr;
  const char *csv_file = nullptr;
  int N = 50, W = 5;
  double flops = 0.0, clock_mhz = 0.0;

  // позиционные: model [input]; флаги: -n RUNS -w WARMUP --csv FILE
  //              --flops F (оп/инференс, для effective TOPS)
  //              --clock-mhz M (клок TPU, для nameplate + efficiency)
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-n") && i + 1 < argc) { N = atoi(argv[++i]); }
    else if (!strcmp(argv[i], "-w") && i + 1 < argc) { W = atoi(argv[++i]); }
    else if (!strcmp(argv[i], "--csv") && i + 1 < argc) { csv_file = argv[++i]; }
    else if (!strcmp(argv[i], "--flops") && i + 1 < argc) { flops = atof(argv[++i]); }
    else if (!strcmp(argv[i], "--clock-mhz") && i + 1 < argc) { clock_mhz = atof(argv[++i]); }
    else if (!model_file) { model_file = argv[i]; }
    else if (!input_file) { input_file = argv[i]; }
  }
  if (!model_file || N < 1) {
    fprintf(stderr,
      "usage: %s model.cvimodel [input.bin] [-n RUNS] [-w WARMUP] [--csv FILE]\n"
      "          [--flops F] [--clock-mhz M]\n"
      "  RUNS=%d WARMUP=%d по умолчанию\n"
      "  --flops это оп/инференс (FLOPs из tpu-mlir module.FLOPs) для TOPS\n"
      "  --clock-mhz это клок TPU для nameplate (2 x %d MAC/такт x clock)\n",
      argv[0], N, W, MAC_PER_CYCLE);
    return 1;
  }

  CVI_MODEL_HANDLE model = nullptr;
  if (CVI_NN_RegisterModel(model_file, &model) != CVI_RC_SUCCESS) {
    fprintf(stderr, "RegisterModel FAIL\n"); return 2;
  }
  int32_t maj = 0, min = 0;
  CVI_NN_GetModelVersion(model, &maj, &min);
  printf("model OK target=%s cvimodel=%d.%d\n",
         CVI_NN_GetModelTarget(model), maj, min);

  CVI_TENSOR *in = nullptr, *out = nullptr; int32_t ni = 0, no = 0;
  if (CVI_NN_GetInputOutputTensors(model, &in, &ni, &out, &no) != CVI_RC_SUCCESS) {
    fprintf(stderr, "GetInputOutputTensors FAIL\n"); return 3;
  }
  printf("inputs=%d outputs=%d  runs=%d warmup=%d\n", ni, no, N, W);
  for (int i = 0; i < no; i++) {
    CVI_TENSOR *t = &out[i];
    printf("  out[%d] %s fmt=%d count=%zu\n",
           i, CVI_NN_TensorName(t), t->fmt, CVI_NN_TensorCount(t));
  }

  // эталонный буфер входа готовим один раз, фаза pre на каждой итерации это
  // memcpy его в тензорный sys_mem (репрезентативная стоимость заливки входа)
  CVI_TENSOR *in0 = &in[0];
  size_t in0_sz = CVI_NN_TensorSize(in0);
  std::vector<uint8_t> ref(in0_sz);
  if (input_file) {
    FILE *f = fopen(input_file, "rb");
    if (!f) { fprintf(stderr, "open input %s failed\n", input_file); return 5; }
    size_t rd = fread(ref.data(), 1, in0_sz, f);
    fclose(f);
    if (rd != in0_sz) {
      fprintf(stderr, "input size mismatch: read %zu need %zu\n", rd, in0_sz);
      return 6;
    }
    printf("input %s loaded %zu bytes\n", input_file, in0_sz);
  } else {
    for (size_t j = 0; j < in0_sz; j++) ref[j] = (uint8_t)(j * 7 + 13); // ramp
    printf("input ramp %zu bytes (без проверки точности)\n", in0_sz);
  }
  // прочие входы (если есть) залить ramp один раз, в замере не трогаем
  for (int i = 1; i < ni; i++) {
    size_t b = CVI_NN_TensorSize(&in[i]);
    uint8_t *p = (uint8_t *)CVI_NN_TensorPtr(&in[i]);
    for (size_t j = 0; j < b; j++) p[j] = (uint8_t)(j * 7 + 13);
  }

  // прогрев: первые forward прогревают кеши/маппинги, в статистику не идут
  for (int i = 0; i < W; i++) {
    memcpy(CVI_NN_TensorPtr(in0), ref.data(), in0_sz);
    CVI_RC rc = CVI_NN_Forward(model, in, ni, out, no);
    if (rc != CVI_RC_SUCCESS) { fprintf(stderr, "warmup Forward FAIL rc=%d\n", rc); return 4; }
  }
  size_t ref_argmax = argmax(&out[0]);

  std::vector<double> pre, fwd, post;
  pre.reserve(N); fwd.reserve(N); post.reserve(N);
  size_t mism = 0;
  FILE *csv = nullptr;
  if (csv_file) {
    csv = fopen(csv_file, "w");
    if (csv) fprintf(csv, "iter,pre_ms,fwd_ms,post_ms\n");
  }

  for (int i = 0; i < N; i++) {
    double t0 = now_ms();
    memcpy(CVI_NN_TensorPtr(in0), ref.data(), in0_sz);
    double t1 = now_ms();
    CVI_RC rc = CVI_NN_Forward(model, in, ni, out, no);
    double t2 = now_ms();
    if (rc != CVI_RC_SUCCESS) { fprintf(stderr, "Forward FAIL rc=%d iter=%d\n", rc, i); return 4; }
    size_t am = argmax(&out[0]);
    double t3 = now_ms();
    if (am != ref_argmax) mism++;
    pre.push_back(t1 - t0);
    fwd.push_back(t2 - t1);
    post.push_back(t3 - t2);
    if (csv) fprintf(csv, "%d,%.4f,%.4f,%.4f\n", i, t1 - t0, t2 - t1, t3 - t2);
  }
  if (csv) fclose(csv);

  std::vector<double> fs = fwd;
  std::sort(fs.begin(), fs.end());
  double fmean = mean_of(fwd), fsd = stddev_of(fwd, fmean);
  double pmean = mean_of(pre), pomean = mean_of(post);
  double pipe = pmean + fmean + pomean;

  printf("\n=== forward latency (мс), N=%d ===\n", N);
  printf("  min   %.3f\n", fs.front());
  printf("  p50   %.3f\n", pct(fs, 50));
  printf("  p90   %.3f\n", pct(fs, 90));
  printf("  p95   %.3f\n", pct(fs, 95));
  printf("  p99   %.3f\n", pct(fs, 99));
  printf("  max   %.3f\n", fs.back());
  printf("  mean  %.3f  stddev %.3f\n", fmean, fsd);

  printf("\n=== throughput ===\n");
  printf("  forward-only  %.1f fps (1000/p50)\n", pct(fs, 50) > 0 ? 1000.0 / pct(fs, 50) : 0.0);
  printf("  pipeline      %.1f fps (1000/(pre+fwd+post) средн.)\n", pipe > 0 ? 1000.0 / pipe : 0.0);

  printf("\n=== разбивка фаз (средн., мс) ===\n");
  printf("  CPU-pre   %.3f  (%.1f%%)  заливка входа\n", pmean, pipe > 0 ? 100.0 * pmean / pipe : 0.0);
  printf("  TPU-fwd   %.3f  (%.1f%%)  CVI_NN_Forward\n", fmean, pipe > 0 ? 100.0 * fmean / pipe : 0.0);
  printf("  CPU-post  %.3f  (%.1f%%)  argmax-скан\n", pomean, pipe > 0 ? 100.0 * pomean / pipe : 0.0);

  // effective TOPS считается по чистой фазе TPU-fwd (без pre/post), что
  // правильный знаменатель. nameplate это паспортный пик при заданном клоке.
  if (flops > 0.0) {
    double tpu_s_p50 = pct(fs, 50) / 1e3, tpu_s_mean = fmean / 1e3;
    double eff_p50 = tpu_s_p50 > 0 ? flops / tpu_s_p50 / 1e12 : 0.0;
    double eff_mean = tpu_s_mean > 0 ? flops / tpu_s_mean / 1e12 : 0.0;
    printf("\n=== TOPS ===\n");
    printf("  FLOPs/инференс   %.0f  (%.3f GFLOP)\n", flops, flops / 1e9);
    printf("  effective       p50 %.4f TOPS   mean %.4f TOPS\n", eff_p50, eff_mean);
    if (clock_mhz > 0.0) {
      double nameplate = 2.0 * MAC_PER_CYCLE * clock_mhz * 1e6 / 1e12;
      printf("  nameplate       %.3f TOPS  (~%d MAC/такт @ %.0f МГц)\n",
             nameplate, MAC_PER_CYCLE, clock_mhz);
      printf("  efficiency      %.1f%%  (p50 effective / nameplate)\n",
             nameplate > 0 ? 100.0 * eff_p50 / nameplate : 0.0);
    }
  }

  printf("\nargmax=%zu mismatches=%zu/%d\n", ref_argmax, mism, N);
  if (csv_file) printf("csv -> %s\n", csv_file);

  CVI_NN_CleanupModel(model);
  printf("BENCH OK\n");
  return mism ? 7 : 0;
}
