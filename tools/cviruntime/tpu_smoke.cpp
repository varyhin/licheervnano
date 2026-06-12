// Минимальный smoke-раннер TPU-датапаса (без argparse/opencv/cnpy).
// Подаёт детерминированный ramp на вход, гонит CVI_NN_Forward, печатает
// argmax выхода + время. Цель: подтвердить, что весь тракт работает на
// железе (runtime -> dma-heap -> ioctl -> ядро -> TPU -> результат).
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <ctime>
#include "cviruntime.h"

#ifndef CVI_RC_SUCCESS
#define CVI_RC_SUCCESS 0
#endif

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

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s model.cvimodel\n", argv[0]); return 1; }

  CVI_MODEL_HANDLE model = nullptr;
  if (CVI_NN_RegisterModel(argv[1], &model) != CVI_RC_SUCCESS) {
    fprintf(stderr, "RegisterModel FAIL\n"); return 2;
  }
  printf("model OK target=%s\n", CVI_NN_GetModelTarget(model));

  CVI_TENSOR *in = nullptr, *out = nullptr; int32_t ni = 0, no = 0;
  if (CVI_NN_GetInputOutputTensors(model, &in, &ni, &out, &no) != CVI_RC_SUCCESS) {
    fprintf(stderr, "GetInputOutputTensors FAIL\n"); return 3;
  }
  printf("inputs=%d outputs=%d\n", ni, no);

  // argv[2] (опц.) это файл с сырым входом (raw, точно под размер 1-го тензора).
  // Без него вход это детерминированный ramp (smoke без проверки точности).
  const char *input_file = (argc >= 3) ? argv[2] : NULL;
  for (int i = 0; i < ni; i++) {
    CVI_TENSOR *t = &in[i];
    size_t b = CVI_NN_TensorSize(t);
    uint8_t *p = (uint8_t *)CVI_NN_TensorPtr(t);
    if (input_file && i == 0) {
      FILE *f = fopen(input_file, "rb");
      if (!f) { fprintf(stderr, "open input %s failed\n", input_file); return 5; }
      size_t rd = fread(p, 1, b, f);
      fclose(f);
      if (rd != b) {
        fprintf(stderr, "input size mismatch: read %zu need %zu\n", rd, b);
        return 6;
      }
      printf("  in[%d] %s loaded %zu bytes from %s\n",
             i, CVI_NN_TensorName(t), b, input_file);
    } else {
      for (size_t j = 0; j < b; j++) p[j] = (uint8_t)(j * 7 + 13); // ramp
      printf("  in[%d] %s fmt=%d bytes=%zu count=%zu (ramp)\n",
             i, CVI_NN_TensorName(t), t->fmt, b, CVI_NN_TensorCount(t));
    }
  }

  struct timespec a, z;
  clock_gettime(CLOCK_MONOTONIC, &a);
  CVI_RC rc = CVI_NN_Forward(model, in, ni, out, no);
  clock_gettime(CLOCK_MONOTONIC, &z);
  if (rc != CVI_RC_SUCCESS) { fprintf(stderr, "Forward FAIL rc=%d\n", rc); return 4; }
  double ms = (z.tv_sec - a.tv_sec) * 1e3 + (z.tv_nsec - a.tv_nsec) / 1e6;
  printf("Forward OK %.2f ms\n", ms);

  for (int i = 0; i < no; i++) {
    CVI_TENSOR *t = &out[i];
    size_t c = CVI_NN_TensorCount(t);
    if (!c) { printf("  out[%d] empty\n", i); continue; }
    size_t best = 0; float bv = get_elem(t, 0), mn = bv, mx = bv;
    for (size_t j = 1; j < c; j++) {
      float v = get_elem(t, j);
      if (v > bv) { bv = v; best = j; }
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    printf("  out[%d] %s fmt=%d count=%zu argmax=%zu val=%.4f range=[%.4f,%.4f]\n",
           i, CVI_NN_TensorName(t), t->fmt, c, best, bv, mn, mx);
  }

  CVI_NN_CleanupModel(model);
  printf("SMOKE OK\n");
  return 0;
}
