// tpu_soak это многочасовой раннер стабильности TPU-датапаса cv181x/SG2002.
// Гонит CVI_NN_Forward в одном персистентном процессе тысячи раз подряд и
// периодически снимает метрики, чтобы поймать то, что разовый smoke/bench не
// видит:
//   - утечку памяти (VmRSS процесса растёт во времени)
//   - утечку дескрипторов (число fd в /proc/self/fd растёт; dma-heap буферы)
//   - деградацию латентности (p50 окна уходит вверх от baseline)
//   - тепловой троттлинг (temp растёт, latency коррелирует)
//   - дрейф корректности под нагрузкой (argmax != reference)
//
// Несколько моделей (round-robin): передать 2+ моделей это чередование разных
// РАЗМЕРОВ буферов в одном процессе. Это эмпирически нагружает когерентность
// кеша на варьировании размеров (stale-cache на конкретном размере всплыл бы как
// дрейф argmax ИМЕННО той модели) и ловит cross-model интерференцию/утечки, чего
// одномодельный прогон не видит. См. docs/tpu_cache_coherency_audit.md.
//
// Один процесс важен: lifecycle тензоров/cmdbuf/dmabuf держится открытым весь
// прогон, поэтому утечка внутри forward-петли видна как монотонный рост RSS/fd.
// Разовый tpu_smoke (новый процесс на forward) такую утечку маскирует.
//
// Метрики читаются из procfs/sysfs самой платы (без внешних зависимостей):
//   VmRSS  <- /proc/self/status
//   fd     <- подсчёт /proc/self/fd
//   temp   <- /sys/class/thermal/thermal_zone0/temp (милли-°C), если есть
//
// Завершение по --duration/--iters или по SIGINT/SIGTERM (Ctrl-C): печатает
// итоговую сводку (включая per-model argmax/mism) и освобождает модели. Код
// выхода 7 при любом расхождении argmax за весь прогон, иначе 0.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cmath>
#include <vector>
#include <string>
#include <algorithm>
#include <csignal>
#include <dirent.h>
#include "cviruntime.h"

#ifndef CVI_RC_SUCCESS
#define CVI_RC_SUCCESS 0
#endif

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

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

static double pct(std::vector<double> s, double p) {
  if (s.empty()) return 0.0;
  std::sort(s.begin(), s.end());
  long idx = (long)std::ceil(p / 100.0 * (double)s.size()) - 1;
  if (idx < 0) idx = 0;
  if (idx >= (long)s.size()) idx = (long)s.size() - 1;
  return s[idx];
}

static long read_rss_kb() {
  FILE *f = fopen("/proc/self/status", "r");
  if (!f) return 0;
  char line[256]; long kb = 0;
  while (fgets(line, sizeof line, f)) {
    if (!strncmp(line, "VmRSS:", 6)) { sscanf(line + 6, "%ld", &kb); break; }
  }
  fclose(f);
  return kb;
}

static int read_fd_count() {
  DIR *d = opendir("/proc/self/fd");
  if (!d) return -1;
  int n = 0; struct dirent *e;
  while ((e = readdir(d))) if (e->d_name[0] != '.') n++;
  closedir(d);
  return n;
}

static double read_temp_c() {
  FILE *f = fopen("/sys/class/thermal/thermal_zone0/temp", "r");
  if (!f) return NAN;
  long milli = 0; int rc = fscanf(f, "%ld", &milli); fclose(f);
  return rc == 1 ? milli / 1000.0 : NAN;
}

static void hhmmss(char *buf, size_t n) {
  time_t now = time(nullptr);
  struct tm tmv; localtime_r(&now, &tmv);
  strftime(buf, n, "%H:%M:%S", &tmv);
}

// одна модель в наборе round-robin
struct Mdl {
  std::string model_file;
  std::string input_file;          // пусто = ramp
  CVI_MODEL_HANDLE model = nullptr;
  CVI_TENSOR *in = nullptr, *out = nullptr;
  int32_t ni = 0, no = 0;
  std::vector<uint8_t> ref;        // эталонный вход (заливается каждую итерацию)
  size_t in0_sz = 0;
  size_t ref_argmax = 0;
  long iters = 0, mism = 0;
  std::string label;               // basename для отчёта
};

static std::string basename_of(const std::string &p) {
  size_t s = p.find_last_of('/');
  return s == std::string::npos ? p : p.substr(s + 1);
}

// загрузка модели + подготовка входа + warmup + ref_argmax; false при ошибке
static bool prep_model(Mdl &m, int warmup) {
  if (CVI_NN_RegisterModel(m.model_file.c_str(), &m.model) != CVI_RC_SUCCESS) {
    fprintf(stderr, "RegisterModel FAIL %s\n", m.model_file.c_str()); return false;
  }
  if (CVI_NN_GetInputOutputTensors(m.model, &m.in, &m.ni, &m.out, &m.no) != CVI_RC_SUCCESS) {
    fprintf(stderr, "GetIO FAIL %s\n", m.model_file.c_str()); return false;
  }
  CVI_TENSOR *in0 = &m.in[0];
  m.in0_sz = CVI_NN_TensorSize(in0);
  m.ref.resize(m.in0_sz);
  if (!m.input_file.empty()) {
    FILE *f = fopen(m.input_file.c_str(), "rb");
    if (!f) { fprintf(stderr, "open input %s failed\n", m.input_file.c_str()); return false; }
    size_t rd = fread(m.ref.data(), 1, m.in0_sz, f); fclose(f);
    if (rd != m.in0_sz) { fprintf(stderr, "input size mismatch %s: %zu need %zu\n",
                                  m.input_file.c_str(), rd, m.in0_sz); return false; }
  } else {
    for (size_t j = 0; j < m.in0_sz; j++) m.ref[j] = (uint8_t)(j * 7 + 13);
  }
  for (int i = 1; i < m.ni; i++) {
    size_t b = CVI_NN_TensorSize(&m.in[i]);
    uint8_t *p = (uint8_t *)CVI_NN_TensorPtr(&m.in[i]);
    for (size_t j = 0; j < b; j++) p[j] = (uint8_t)(j * 7 + 13);
  }
  for (int i = 0; i < warmup; i++) {
    memcpy(CVI_NN_TensorPtr(in0), m.ref.data(), m.in0_sz);
    if (CVI_NN_Forward(m.model, m.in, m.ni, m.out, m.no) != CVI_RC_SUCCESS) {
      fprintf(stderr, "warmup FAIL %s\n", m.model_file.c_str()); return false;
    }
  }
  m.ref_argmax = argmax(&m.out[0]);
  m.label = basename_of(m.model_file);
  return true;
}

// один forward модели m, возвращает латентность в мс (или -1 при ошибке)
static double run_once(Mdl &m) {
  memcpy(CVI_NN_TensorPtr(&m.in[0]), m.ref.data(), m.in0_sz);
  double a = now_ms();
  CVI_RC rc = CVI_NN_Forward(m.model, m.in, m.ni, m.out, m.no);
  double ms = now_ms() - a;
  if (rc != CVI_RC_SUCCESS) return -1.0;
  if (argmax(&m.out[0]) != m.ref_argmax) m.mism++;
  m.iters++;
  return ms;
}

int main(int argc, char **argv) {
  std::vector<Mdl> mdls;
  const char *csv_file = nullptr;
  double duration_s = 0.0;
  long   iters_max  = 0;
  double report_s   = 60.0;
  int    warmup     = 5;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--duration") && i + 1 < argc) duration_s = atof(argv[++i]);
    else if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters_max = atol(argv[++i]);
    else if (!strcmp(argv[i], "--report-sec") && i + 1 < argc) report_s = atof(argv[++i]);
    else if (!strcmp(argv[i], "-w") && i + 1 < argc) warmup = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--csv") && i + 1 < argc) csv_file = argv[++i];
    else {
      // позиционный: model[,input]
      Mdl m;
      std::string a = argv[i];
      size_t c = a.find(',');
      if (c == std::string::npos) m.model_file = a;
      else { m.model_file = a.substr(0, c); m.input_file = a.substr(c + 1); }
      mdls.push_back(std::move(m));
    }
  }
  if (mdls.empty()) {
    fprintf(stderr,
      "usage: %s model1[,input1] [model2[,input2] ...] [--duration SEC]\n"
      "          [--iters N] [--report-sec S] [-w WARMUP] [--csv FILE]\n"
      "  2+ моделей = round-robin (варьирование размеров, тест когерентности кеша)\n"
      "  без --duration/--iters гонит до Ctrl-C\n",
      argv[0]);
    return 1;
  }

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  setvbuf(stdout, nullptr, _IOLBF, 0);

  for (auto &m : mdls) if (!prep_model(m, warmup)) return 2;
  printf("soak: %zu модель(ей) round-robin\n", mdls.size());
  for (auto &m : mdls)
    printf("  %-32s in0=%zuB argmax=%zu\n", m.label.c_str(), m.in0_sz, m.ref_argmax);
  long rss0 = read_rss_kb(); int fd0 = read_fd_count();
  printf("baseline rss=%.1fMB fd=%d temp=%.1fC, report каждые %.0fs%s\n",
         rss0 / 1024.0, fd0, read_temp_c(), report_s,
         (duration_s <= 0 && iters_max <= 0) ? " (до Ctrl-C)" : "");

  FILE *csv = nullptr;
  if (csv_file) {
    csv = fopen(csv_file, "w");
    if (csv) fprintf(csv, "elapsed_s,iters,p50_ms,p99_ms,rss_kb,fd,temp_c,mism_total\n");
  }

  double t_start = now_ms();
  double t_next = t_start + report_s * 1e3;
  std::vector<double> win;
  win.reserve(8192);
  long total = 0, mism_total = 0;
  double base_p50 = 0.0;
  long max_rss = rss0; int max_fd = fd0;
  double max_temp = -1e9, max_p99 = 0.0;

  while (!g_stop) {
    Mdl &m = mdls[total % mdls.size()];   // round-robin: соседние итерации = разные размеры
    double ms = run_once(m);
    if (ms < 0) { fprintf(stderr, "Forward FAIL %s iter=%ld\n", m.label.c_str(), total); g_stop = 1; break; }
    win.push_back(ms);
    total++;
    mism_total = 0; for (auto &mm : mdls) mism_total += mm.mism;

    double tnow = now_ms();
    bool last = (iters_max > 0 && total >= iters_max) ||
                (duration_s > 0 && (tnow - t_start) >= duration_s * 1e3);
    if (tnow >= t_next || last || g_stop) {
      double p50 = pct(win, 50), p99 = pct(win, 99);
      long rss = read_rss_kb(); int fd = read_fd_count(); double temp = read_temp_c();
      if (base_p50 == 0.0) base_p50 = p50;
      if (rss > max_rss) max_rss = rss;
      if (fd > max_fd) max_fd = fd;
      if (!std::isnan(temp) && temp > max_temp) max_temp = temp;
      if (p99 > max_p99) max_p99 = p99;
      char ts[16]; hhmmss(ts, sizeof ts);
      printf("[%s] +%6.0fs iter=%-8ld p50=%.2f p99=%.2f (Δp50 %+.2f) "
             "rss=%.1fMB (Δ%+ld kB) fd=%d (Δ%+d) temp=%.1fC mism=%ld\n",
             ts, (tnow - t_start) / 1e3, total, p50, p99, p50 - base_p50,
             rss / 1024.0, rss - rss0, fd, fd - fd0, temp, mism_total);
      if (csv) {
        fprintf(csv, "%.0f,%ld,%.4f,%.4f,%ld,%d,%.1f,%ld\n",
                (tnow - t_start) / 1e3, total, p50, p99, rss, fd, temp, mism_total);
        fflush(csv);
      }
      win.clear();
      t_next = tnow + report_s * 1e3;
      if (last) break;
    }
  }
  if (csv) fclose(csv);

  double elapsed = (now_ms() - t_start) / 1e3;
  long rss_end = read_rss_kb();
  printf("\n=== soak summary ===\n");
  printf("  iters         %ld за %.0fs (%.1f/s), %zu модель(ей) round-robin\n",
         total, elapsed, elapsed > 0 ? total / elapsed : 0.0, mdls.size());
  printf("  RSS           start %.1fMB  end %.1fMB  max %.1fMB  Δ%+ld kB\n",
         rss0 / 1024.0, rss_end / 1024.0, max_rss / 1024.0, rss_end - rss0);
  printf("  fd            start %d  end %d  max %d\n", fd0, read_fd_count(), max_fd);
  printf("  latency p99   max за прогон %.2f ms\n", max_p99);
  printf("  temp          max %.1fC\n", max_temp);
  printf("  per-model (argmax дрейф = баг когерентности на этом размере):\n");
  for (auto &m : mdls)
    printf("    %-32s iters=%-7ld in0=%-8zuB argmax=%-6zu mism=%ld\n",
           m.label.c_str(), m.iters, m.in0_sz, m.ref_argmax, m.mism);
  printf("  verdict       %s\n", mism_total == 0 ? "argmax стабилен на всех размерах" : "ВНИМАНИЕ: argmax дрейфовал");

  for (auto &m : mdls) CVI_NN_CleanupModel(m.model);
  printf("SOAK %s\n", mism_total ? "FAIL" : "OK");
  return mism_total ? 7 : 0;
}
