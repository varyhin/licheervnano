#!/bin/sh
# Проверенный разгон TPU cv181x до 900 МГц с гейтом по СТАБИЛЬНОСТИ компьютинга.
# Запускать из этого каталога (рядом bin/ lib/ models/). Напряжение НЕ трогается,
# всё обратимо (revert и перезагрузка).
#
# Логика: снимаем argmax на штатных 700 как эталон (любой стабильный класс),
# разгоняем до 900, требуем ТОТ ЖЕ argmax. Совпал = компьютинг стабилен на 900.
# Не совпал = 900 без поднятия напряжения нестабилен, авто-откат.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
export LD_LIBRARY_PATH="$HERE/lib:${LD_LIBRARY_PATH:-}"
SMOKE="$HERE/bin/tpu_smoke"
MNET="$HERE/models/mobilenet_v2_bf16.cvimodel"
DOG="$HERE/input_dog.bin"

amax() { "$SMOKE" "$MNET" "$DOG" 2>/dev/null | grep -o 'argmax=[0-9]*' | head -1 | cut -d= -f2; }

for need in "$SMOKE" "$MNET" "$DOG"; do
  [ -f "$need" ] || { echo "НЕ НАЙДЕНО: $need (запускай из каталога kit)"; exit 1; }
done

echo "== эталон @700 (штатный клок) =="
ref=$(amax); echo "  argmax@700=${ref:-<пусто>}"
if [ -z "$ref" ]; then
  echo "  smoke не дал argmax, разгон отменён."
  echo "  Диагностика: LD_LIBRARY_PATH=lib bin/tpu_smoke models/mobilenet_v2_bf16.cvimodel input_dog.bin"
  exit 1
fi

echo "== разгон -> 900 МГц =="
python3 "$HERE/set_tpu_clk.py" 900 || exit 1

echo "== стабильность @900 (должно совпасть с $ref) =="
a=$(amax); echo "  argmax@900=${a:-<пусто>}"
if [ "$a" != "$ref" ]; then
  echo "  !! argmax изменился ($ref -> ${a:-<пусто>}): 900 МГц НЕстабильно при 0.96В, откат"
  python3 "$HERE/set_tpu_clk.py" revert
  exit 1
fi

echo "== стабильно (argmax совпал), замер @900 =="
CLK_MHZ=900 RUNS="${RUNS:-50}" "$HERE/tpu_maxtops.sh"

echo "== откат -> 700 =="
python3 "$HERE/set_tpu_clk.py" revert
echo "готово. Оставить 900: python3 set_tpu_clk.py 900  (сбросится перезагрузкой)"
