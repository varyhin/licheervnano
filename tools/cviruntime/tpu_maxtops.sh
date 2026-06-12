#!/bin/sh
# On-board харнес замера максимума TPU cv181x/SG2002.
# Читает живой клок TPU, гоняет saturating INT8-модели через tpu_bench,
# печатает паспортный пик, достигнутый максимум и его процент.
# Запускать НА ПЛАТЕ из распакованного бандла (нужен soph_tpu + CMA dma-heap).
#
# Использование:  ./tpu_maxtops.sh            (клок определяется сам)
#                 CLK_MHZ=700 ./tpu_maxtops.sh  (форсить клок)
#                 RUNS=100 ./tpu_maxtops.sh      (число прогонов)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
export LD_LIBRARY_PATH="$HERE/lib:${LD_LIBRARY_PATH:-}"
BENCH="$HERE/bin/tpu_bench"
MODELS="$HERE/models"
RUNS="${RUNS:-50}"

# --- детекция клока TPU (МГц) ---
detect_clk() {
  if [ -n "${CLK_MHZ:-}" ]; then echo "$CLK_MHZ"; return; fi
  # 1) clk-framework debugfs (rate в Гц, без битовой арифметики)
  mount -t debugfs none /sys/kernel/debug 2>/dev/null
  r=$(cat /sys/kernel/debug/clk/clk_tpu/clk_rate 2>/dev/null)
  if [ -z "$r" ] || [ "$r" = "0" ]; then
    r=$(awk '$1=="clk_tpu"{print $5; exit}' /sys/kernel/debug/clk/clk_summary 2>/dev/null)
  fi
  if [ -n "$r" ] && [ "$r" != "0" ]; then echo $((r / 1000000)); return; fi
  # 2) сырой регистр REG_DIV_CLK_TPU (делитель [19:16]), TPLL это память
  if command -v devmem >/dev/null 2>&1; then
    v=$(devmem 0x03002054 2>/dev/null)
    if [ -n "$v" ]; then
      div=$(( (v >> 16) & 0xF ))
      [ "$div" -gt 0 ] && echo " tpu div=$div (REG_DIV_CLK_TPU=$v), TPLL читать вручную" >&2
    fi
  fi
  echo "700"  # fallback: perf-режим FSBL это TPU=700 МГц
}

CLK=$(detect_clk)
echo "================ TPU max TOPS ================"
echo "TPU clock      ~${CLK} MHz  (nameplate ~$(awk "BEGIN{printf \"%.2f\", ${CLK}/1000}") TOPS, ~512 MAC/такт)"
echo "runs/model     ${RUNS}"
echo

# manifest: базовое_имя<пробел>FLOPs(оп/инференс из tpu-mlir module.FLOPs).
# Для каждого предпочитаем _io8 (INT8 I/O, без CPU-конверсии) затем _int8 (FP32 I/O).
MANIFEST="
conv1x1_c256_s64 536870912
gemm_m256_k1024_n1024 536870912
conv1x1_c512_s64 2147483648
conv3x3_c256_s64 4831838208
conv3x3_c384_s48 6115295232
"

best=0; best_name=""
printf "%-32s %10s %10s %8s\n" "model" "fwd_p50ms" "eff_TOPS" "%peak"
printf "%-32s %10s %10s %8s\n" "--------------------------------" "----------" "----------" "--------"
echo "$MANIFEST" | while read -r base flops; do
  [ -z "$base" ] && continue
  m=""
  for cand in "${base}_io8.cvimodel" "${base}_int8.cvimodel"; do
    [ -f "$MODELS/$cand" ] && { m="$cand"; break; }
  done
  [ -z "$m" ] && { printf "%-32s  (нет файла)\n" "$base"; continue; }
  f="$MODELS/$m"
  out=$("$BENCH" "$f" -n "$RUNS" --flops "$flops" --clock-mhz "$CLK" 2>/dev/null)
  p50=$(echo "$out" | awk '/^  p50/{print $2; exit}')
  eff=$(echo "$out" | awk '/effective/{print $3; exit}')
  pk=$(echo "$out"  | awk '/efficiency/{print $2; exit}')
  printf "%-32s %10s %10s %8s\n" "$m" "${p50:-?}" "${eff:-?}" "${pk:-?}"
  # лог максимума во временный файл (subshell pipe не делится переменными)
  echo "$eff $m" >> /tmp/_maxtops.$$
done

echo
if [ -f /tmp/_maxtops.$$ ]; then
  sort -gr /tmp/_maxtops.$$ | head -1 | while read -r v n; do
    echo "МАКСИМУМ: $v TOPS на $n  (из ~$(awk "BEGIN{printf \"%.2f\", ${CLK}/1000}") TOPS паспортных)"
  done
  rm -f /tmp/_maxtops.$$
fi
echo "============================================="
