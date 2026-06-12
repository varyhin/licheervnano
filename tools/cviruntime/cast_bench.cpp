// cast_bench это микробенч ПРИРОДЫ узла fp32<->int8 кастов I/O рантайма TPU.
// Замер 2026-06-03 (yolov5s) показал, что ~86% латентности INT8-инференса это
// квант/dequant I/O в userspace cviruntime (~125 нс/элем на C906), а не сам TPU.
// Две конкурирующие гипотезы с РАЗНЫМИ фиксами:
//   (1) узел чисто вычислительный  -> скалярный цикл на rv64gc (NEON-путь в
//       quant.cpp только под ARM); фикс это векторизация RVV/xtheadvector.
//   (2) узел это память            -> буферы рантайма в dma-heap CMA мапятся
//       НЕкэшируемыми, каждый доступ это round-trip к DRAM; фикс это копия в
//       кэшируемый буфер перед кастом, RVV не поможет.
// Тест различает их: один и тот же скалярный каст гоняется над (A) обычной
// malloc-памятью (кэшируемой) и (B) dma-heap буфером (как у рантайма). Если
// B >> A это виновата память (гипотеза 2); если A ~= B ~= 125нс это вычисление
// (гипотеза 1). Ничего не пишет в систему, безопасно гонять на плате.
//
// Сборка (хост): riscv64-linux-gnu-g++ -O2 -march=rv64gc -Wall -Wextra -Werror
//                cast_bench.cpp -o cast_bench
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <ctime>
#include <vector>
#include <algorithm>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

// dma-heap uapi (объявляем вручную, чтобы не зависеть от заголовков sysroot)
struct dma_heap_allocation_data {
  uint64_t len;
  uint32_t fd;
  uint32_t fd_flags;
  uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

static inline signed char float2int8(float v) {
  int i = (int)lrintf(v);
  if (i > 127) return 127;
  if (i < -128) return -128;
  return (signed char)i;
}

static double now_ms() {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// dequant int8->fp32: out[i] = in[i]*scale (как quant.cpp:142, riscv fallback)
static void dequant(const int8_t *in, float *out, int n, float scale) {
  for (int i = 0; i < n; i++) out[i] = in[i] * scale;
}
// quant fp32->int8: float2int8(in[i]*scale) (как quant.cpp:250, riscv fallback)
static void quant(const float *in, int8_t *out, int n, float scale) {
  for (int i = 0; i < n; i++) out[i] = float2int8(in[i] * scale);
}

// медиана нс/элем по R прогонам, op: 0=dequant 1=quant
static double bench(const void *src, void *dst, int n, int R, int op, float scale) {
  std::vector<double> v;
  for (int r = 0; r < R; r++) {
    double a = now_ms();
    if (op == 0) dequant((const int8_t *)src, (float *)dst, n, scale);
    else         quant((const float *)src, (int8_t *)dst, n, scale);
    double ms = now_ms() - a;
    v.push_back(ms * 1e6 / n); // нс на элемент
  }
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

// аллокация пары буферов из dma-heap (fp32 N + int8 N); 0 при успехе
static int alloc_dmaheap(const char *heap, int n, float **f, int8_t **i8,
                         int *fd_f, int *fd_i) {
  int hfd = open(heap, O_RDWR | O_CLOEXEC);
  if (hfd < 0) return -1;
  auto one = [&](uint64_t len, int *ofd, void **ptr) -> int {
    struct dma_heap_allocation_data d = {};
    d.len = len; d.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) return -1;
    void *m = mmap(nullptr, len, PROT_READ | PROT_WRITE, MAP_SHARED, d.fd, 0);
    if (m == MAP_FAILED) { close(d.fd); return -1; }
    *ofd = d.fd; *ptr = m; return 0;
  };
  int rc = one((uint64_t)n * 4, fd_f, (void **)f) | one((uint64_t)n, fd_i, (void **)i8);
  close(hfd);
  return rc;
}

int main(int argc, char **argv) {
  int n = (argc > 1) ? atoi(argv[1]) : 4 * 1024 * 1024; // ~4M элементов
  int R = (argc > 2) ? atoi(argv[2]) : 9;
  float scale = 0.0078125f; // 1/128, типичный qscale
  printf("cast_bench: n=%d элементов, R=%d прогонов, scale=%g\n", n, R, scale);

  // (A) обычная malloc-память (кэшируемая)
  float  *mf = (float *)aligned_alloc(64, (size_t)n * 4);
  int8_t *mi = (int8_t *)aligned_alloc(64, (size_t)n);
  for (int i = 0; i < n; i++) { mi[i] = (int8_t)(i * 7 + 13); mf[i] = (float)((i % 255) - 128); }
  // прогрев страниц
  dequant(mi, mf, n, scale); quant(mf, mi, n, scale);
  double a_dq = bench(mi, mf, n, R, 0, scale);
  double a_q  = bench(mf, mi, n, R, 1, scale);
  printf("\n[A] malloc (кэшируемая):\n");
  printf("    dequant int8->fp32  %.2f нс/элем\n", a_dq);
  printf("    quant   fp32->int8  %.2f нс/элем\n", a_q);

  // (B) dma-heap (как буферы рантайма). Пробуем доступные heap-имена.
  const char *heaps[] = {"/dev/dma_heap/reserved",
                         "/dev/dma_heap/default_cma_region",
                         "/dev/dma_heap/system"};
  float *df = nullptr; int8_t *di = nullptr; int fdf = -1, fdi = -1;
  const char *used = nullptr;
  for (auto h : heaps) {
    if (alloc_dmaheap(h, n, &df, &di, &fdf, &fdi) == 0) { used = h; break; }
  }
  if (used) {
    for (int i = 0; i < n; i++) { di[i] = (int8_t)(i * 7 + 13); df[i] = (float)((i % 255) - 128); }
    dequant(di, df, n, scale); quant(df, di, n, scale); // прогрев
    double b_dq = bench(di, df, n, R, 0, scale);
    double b_q  = bench(df, di, n, R, 1, scale);
    printf("\n[B] dma-heap %s:\n", used);
    printf("    dequant int8->fp32  %.2f нс/элем\n", b_dq);
    printf("    quant   fp32->int8  %.2f нс/элем\n", b_q);
    printf("\n=== вердикт ===\n");
    double rdq = b_dq / a_dq, rq = b_q / a_q;
    printf("    B/A dequant %.1fx, quant %.1fx\n", rdq, rq);
    if (rdq > 3.0 || rq > 3.0)
      printf("    -> ПАМЯТЬ (dma-heap некэшируем): фикс это копия в кэш-буфер; RVV вторично\n");
    else if (a_q > 40.0 || a_dq > 40.0)
      printf("    -> ВЫЧИСЛЕНИЕ (скалярный каст дорог даже в кэше): фикс это RVV\n");
    else
      printf("    -> каст в кэше дёшев и dma-heap не штрафует: узел НЕ здесь, перепроверить атрибуцию\n");
    munmap(df, (size_t)n * 4); munmap(di, (size_t)n);
    if (fdf >= 0) close(fdf);
    if (fdi >= 0) close(fdi);
  } else {
    printf("\n[B] dma-heap: не удалось аллоцировать (нет доступа к /dev/dma_heap/*)\n");
    printf("    только [A] измерен. Если [A] ~125нс это ВЫЧИСЛЕНИЕ (RVV);\n");
    printf("    если [A] мал (<10нс) это узел в ПАМЯТИ, нужен прогон с dma-heap.\n");
  }

  free(mf); free(mi);
  printf("\ncast_bench OK\n");
  return 0;
}
