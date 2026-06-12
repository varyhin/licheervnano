// Раннер yolov5s на TPU cv181x. Модель скомпилирована с --add_postprocess
// yolov5, поэтому выход это уже финальные боксы (TPU считает 1x25200x85, CPU
// yolo_post делает декод+NMS). По исходнику рантайма YoloDetectionFunc пишет
// 6 float на детекцию ПОДРЯД: [x_center, y_center, w, h, cls, score] в
// координатах входа сети (640). Тензор объявлен [1,1,200,7] (7 это аллокация,
// данные упакованы по stride). stride настраивается, layout сверяем на железе.
//
// Вход подаётся сырыми байтами под размер входного тензора (как tpu_smoke):
// препроцесс кадра (letterbox 640x640, RGB, нормировка/квант) делается на хосте.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include "cviruntime.h"

#ifndef CVI_RC_SUCCESS
#define CVI_RC_SUCCESS 0
#endif

static double now_ms() {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static const char *coco80[] = {
  "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
  "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
  "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
  "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
  "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
  "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
  "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair",
  "couch","potted plant","bed","dining table","toilet","tv","laptop","mouse",
  "remote","keyboard","cell phone","microwave","oven","toaster","sink",
  "refrigerator","book","clock","vase","scissors","teddy bear","hair drier",
  "toothbrush"};

int main(int argc, char **argv) {
  const char *model_file = nullptr, *input_file = nullptr;
  int stride = 6, maxbox = 50, runs = 1;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--stride") && i + 1 < argc) stride = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--max") && i + 1 < argc) maxbox = atoi(argv[++i]);
    else if (!strcmp(argv[i], "-n") && i + 1 < argc) runs = atoi(argv[++i]);
    else if (!model_file) model_file = argv[i];
    else if (!input_file) input_file = argv[i];
  }
  if (!model_file) {
    fprintf(stderr, "usage: %s model.cvimodel [input.bin] [--stride N] [--max M] [-n RUNS]\n", argv[0]);
    return 1;
  }

  CVI_MODEL_HANDLE model = nullptr;
  if (CVI_NN_RegisterModel(model_file, &model) != CVI_RC_SUCCESS) { fprintf(stderr, "RegisterModel FAIL\n"); return 2; }
  printf("model OK target=%s\n", CVI_NN_GetModelTarget(model));

  CVI_TENSOR *in = nullptr, *out = nullptr; int32_t ni = 0, no = 0;
  if (CVI_NN_GetInputOutputTensors(model, &in, &ni, &out, &no) != CVI_RC_SUCCESS) { fprintf(stderr, "GetIO FAIL\n"); return 3; }

  // вход: сырые байты из файла под 1-й тензор, иначе ramp
  CVI_TENSOR *in0 = &in[0];
  size_t isz = CVI_NN_TensorSize(in0);
  uint8_t *ip = (uint8_t *)CVI_NN_TensorPtr(in0);
  printf("input %s fmt=%d bytes=%zu\n", CVI_NN_TensorName(in0), in0->fmt, isz);
  if (input_file) {
    FILE *f = fopen(input_file, "rb");
    if (!f) { fprintf(stderr, "open %s failed\n", input_file); return 5; }
    size_t rd = fread(ip, 1, isz, f); fclose(f);
    if (rd != isz) { fprintf(stderr, "input size mismatch read %zu need %zu\n", rd, isz); return 6; }
    printf("loaded %zu bytes from %s\n", isz, input_file);
  } else {
    for (size_t j = 0; j < isz; j++) ip[j] = (uint8_t)(j * 7 + 13);
    printf("ramp input (без проверки боксов)\n");
  }

  double best = 1e9;
  for (int r = 0; r < runs; r++) {
    double a = now_ms();
    if (CVI_NN_Forward(model, in, ni, out, no) != CVI_RC_SUCCESS) { fprintf(stderr, "Forward FAIL\n"); return 4; }
    double ms = now_ms() - a; if (ms < best) best = ms;
  }
  printf("Forward best %.2f ms (runs=%d)\n", best, runs);

  // размер входа сети для масштабирования боксов (выход нормирован в [0,1])
  CVI_SHAPE ish = CVI_NN_TensorShape(in0);
  float net_h = ish.dim_size >= 4 ? (float)ish.dim[2] : 640.f;
  float net_w = ish.dim_size >= 4 ? (float)ish.dim[3] : 640.f;

  // выход с боксами (CPU yolo_post). Печатаем сырой дамп + разбор по stride.
  CVI_TENSOR *o = &out[0];
  CVI_SHAPE sh = CVI_NN_TensorShape(o);
  size_t cnt = CVI_NN_TensorCount(o);
  float *od = (float *)CVI_NN_TensorPtr(o);
  printf("output %s fmt=%d shape=[", CVI_NN_TensorName(o), o->fmt);
  for (size_t d = 0; d < sh.dim_size; d++) printf("%d%s", sh.dim[d], d + 1 < sh.dim_size ? "," : "");
  printf("] count=%zu\n", cnt);

  printf("raw[0..23]:");
  for (size_t k = 0; k < cnt && k < 24; k++) printf(" %.3f", od[k]);
  printf("\n");

  printf("boxes (stride=%d: x_c y_c w h cls score; коорд нормир.[0,1], печать ×вход):\n", stride);
  int shown = 0;
  for (size_t k = 0; k + (size_t)stride <= cnt && shown < maxbox; k += stride) {
    float *d = od + k;
    float score = d[5], cls = d[4];
    // пустой бокс это вся группа нули
    int allzero = 1; for (int t = 0; t < stride; t++) if (d[t] != 0.f) { allzero = 0; break; }
    if (allzero) break;
    int ci = (int)(cls + 0.5f);
    const char *nm = (ci >= 0 && ci < 80) ? coco80[ci] : "?";
    printf("  [%2d] cls=%2d(%-12s) score=%.3f  box_px=(%.0f,%.0f,%.0f,%.0f)\n",
           shown, ci, nm, score, d[0] * net_w, d[1] * net_h, d[2] * net_w, d[3] * net_h);
    shown++;
  }
  printf("detections=%d\n", shown);

  CVI_NN_CleanupModel(model);
  printf("YOLO OK\n");
  return 0;
}
