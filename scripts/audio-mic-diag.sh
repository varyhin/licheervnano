#!/bin/bash
# Диагностика захвата внутреннего микрофона LicheeRV Nano (card0, dev0).
# Копировать на плату и запускать (лежит в образе в /root). Зависимостей нет:
# только arecord + od + awk (python/sox на плате нет). Пер-канальная статистика
# (rms, min, max, peak, p90) считается без бинарей.
#
# Что показывает: пишем сырое стерео (-c 2) = два I2S-слота. Каждый слот несёт
# один из двух аналоговых входов ADC (мик на AUD_AINL + неподключённый второй).
# Усиление СИММЕТРИЧНОЕ <gain>,<gain> (оба аналоговых входа одинаково), чтобы
# видеть оба слота и где реально сигнал, без перекоса.
#
# Диагноз (win.sh + phase-hist на железе): модулятор ADC стабилен, а десериализатор
# I2S RX выходит из reset в СЛУЧАЙНОЙ фазе кадра на КАЖДОМ открытии захвата. Это даёт
# две беды разом: случайный битовый сдвиг (уровень множится/делится на 2^k это лесенка
# p90 ~1/8..×4 вокруг истинного уровня) и случайный словный сдвиг (мик то на L, то на R).
# Внутри одной записи фаза фиксирована (уровень ровный), скачет ИМЕННО между записями.
# Драйвер v3 (cv1800b_sync_reset_rx в trigger START): assert RX reset целым словом ->
# поллинг RX_STATUS бит23 RESET_RX_SCLK -> release, то есть SCLK-синхронный reset. Это
# должно сделать фазу ДЕТЕРМИНИРОВАННОЙ: один и тот же слот И один и тот же уровень на
# всех открытиях. Скрипт печатает ОБА слота целиком (rms/min/max/peak/p90) + лог драйвера
# (dev_info/dev_warn из dmesg) по каждому захвату. Строка "not SCLK-synced" в логе =
# поллинг истёк по таймауту, фаза могла остаться случайной (v3 не сработал в этом захвате).
#
# Использование:
#   audio-mic-diag.sh [gain] [повторов] [секунд]
#     gain     0..24, усиление ОБОИХ аналоговых каналов, по умолчанию 8
#     повторов сколько записей подряд, по умолчанию 6
#     секунд   длительность каждой записи, по умолчанию 5
set -u
CARD=0
GAIN=${1:-8}
REPS=${2:-6}
SECS=${3:-5}
OUT=/tmp/micdiag
mkdir -p "$OUT"

echo "=================================================================="
echo "mic diag: gain=$GAIN,$GAIN  повторов=$REPS  по ${SECS}с  card$CARD dev0"
echo "вход держать ПОСТОЯННЫМ (один и тот же звук каждый повтор)"
echo "оба слота показаны целиком; мик должен стабильно быть в ОДНОМ слоте"
echo "=================================================================="
amixer -c "$CARD" cset numid=1 "$GAIN","$GAIN" >/dev/null 2>&1
echo "numid=1 -> $(amixer -c "$CARD" cget numid=1 | awk -F: '/: values/{print $2}')"

# Пер-канальная статистика + разбор стерео на два моно-WAV за ОДИН проход od
# (важно для медленного C906). Аргументы: $1 стерео-wav, $2 выход L, $3 выход R.
# Один awk и считает stats (rms/min/max/peak; p90 это 90-й перцентиль |sample|
# через гистограмму шагом 32, board-awk без sort), и пишет два валидных моно-WAV
# (заголовок + сэмплы через printf "%c"). Возвращает в stdout 10 чисел:
#   Lrms Lmin Lmax Lpeak Lp90  Rrms Rmin Rmax Rpeak Rp90
analyze() {  # $1 стерео  $2 Lout  $3 Rout
  local sz frames data
  sz=$(stat -c%s "$1"); frames=$(( (sz-44)/4 )); data=$(( frames*2 ))
  tail -c +45 "$1" | od -An -v -td2 -w4 | awk -v data="$data" -v lout="$2" -v rout="$3" '
    function abs(x){ return x<0?-x:x }
    function b(x,f){ x=int(x)%256; if(x<0)x+=256; printf "%c", x > f }
    function le16(x,f){ b(x,f); b(int(x/256),f) }
    function le32(x,f){ b(x,f); b(int(x/256),f); b(int(x/65536),f); b(int(x/16777216),f) }
    function hdr(f){ printf "RIFF" > f; le32(36+data,f); printf "WAVEfmt " > f; le32(16,f);
                     le16(1,f); le16(1,f); le32(48000,f); le32(96000,f); le16(2,f); le16(16,f);
                     printf "data" > f; le32(data,f) }
    BEGIN{ hdr(lout); hdr(rout) }
    {
      l=$1+0; r=$2+0; n++;
      sl+=l*l; sr+=r*r;
      if (n==1){ lmin=lmax=l; rmin=rmax=r }
      else { if(l<lmin)lmin=l; if(l>lmax)lmax=l; if(r<rmin)rmin=r; if(r>rmax)rmax=r }
      al=abs(l); ar=abs(r);
      if(al>lpk)lpk=al; if(ar>rpk)rpk=ar;
      lh[int(al/32)]++; rh[int(ar/32)]++;
      le16(l<0?l+65536:l, lout); le16(r<0?r+65536:r, rout);
    }
    END{
      close(lout); close(rout);
      if(!n){ printf "0 0 0 0 0 0 0 0 0 0"; exit }
      t=0.9*n;
      c=0; for(bb=0;bb<=1024;bb++){ c+=lh[bb]; if(c>=t){ lp90=bb*32; break } }
      c=0; for(bb=0;bb<=1024;bb++){ c+=rh[bb]; if(c>=t){ rp90=bb*32; break } }
      printf "%.0f %d %d %d %d %.0f %d %d %d %d",
        sqrt(sl/n),lmin,lmax,lpk,lp90, sqrt(sr/n),rmin,rmax,rpk,rp90;
    }'
}

# Классификация канала по rms/peak.
cls() {  # $1=rms $2=peak
  if [ "$2" -lt 300 ]; then echo "мёртв"
  elif [ "$2" -lt 1500 ]; then echo "тихо"
  elif [ "$1" -gt 14000 ]; then echo "РЕЛЬС"
  elif [ "$2" -ge 32760 ]; then echo "КЛИП"
  else echo "ok"; fi
}

# Строки лога драйвера (dev_info/dev_warn) за один захват.
# SCLK это маркер от cv1800b_sync_reset_rx (v3): печатается только при таймауте поллинга.
DRV='\[DONE\]|\[FAIL\]|cfg done|settle|SCLK'

RUN0=$(dmesg 2>/dev/null | wc -l)   # позиция kmsg на старте прогона (для полного лога)
alive=0; dead=0; rail=0; loudR=0; loudL=0; stageok=0
for i in $(seq 1 "$REPS"); do
  f="$OUT/r$i.wav"; fL="$OUT/r${i}_L.wav"; fR="$OUT/r${i}_R.wav"
  prev=$(dmesg 2>/dev/null | wc -l)   # запомнить позицию kmsg, буфер НЕ чистим
  arecord -D hw:${CARD},0 -c 2 -r 48000 -f S16_LE -d "$SECS" "$f" >/dev/null 2>&1
  set -- $(analyze "$f" "$fL" "$fR")
  Lr=$1; Lmin=$2; Lmax=$3; Lp=$4; Lp90=$5; Rr=$6; Rmin=$7; Rmax=$8; Rp=$9; Rp90=${10}
  Lc=$(cls "$Lr" "$Lp"); Rc=$(cls "$Rr" "$Rp")
  alivecap=0
  case "$Lc$Rc" in *ok*|*КЛИП*) alivecap=1;; esac
  if [ "$Lc" = "РЕЛЬС" ] || [ "$Rc" = "РЕЛЬС" ]; then loud="рельс"; rail=$((rail+1))
  elif [ "$alivecap" = 1 ]; then
    if [ "$Rr" -ge "$Lr" ]; then loud="R/slot1"; loudR=$((loudR+1)); else loud="L/slot0"; loudL=$((loudL+1)); fi
    alive=$((alive+1))
  else loud="мёртво"; dead=$((dead+1)); fi
  echo
  echo "=== запуск $i/$REPS  громче: $loud ==="
  echo "L slot0 rms=$Lr peak=$Lp min=$Lmin max=$Lmax p90=$Lp90 [$Lc]"
  echo "R slot1 rms=$Rr peak=$Rp min=$Rmin max=$Rmax p90=$Rp90 [$Rc]"
  drv=$(dmesg 2>/dev/null | tail -n +$((prev+1)) | grep -aE "$DRV" | sed -E 's/^\[[0-9. ]+\] [^:]+: //')
  echo "$drv"
  # подсчёт стадий по индикатору [DONE]/[FAIL] в начале строки
  ndone=$(echo "$drv" | grep -c '^\[DONE\]')
  nfail=$(echo "$drv" | grep -c '^\[FAIL\]')
  echo "стадии: DONE=$ndone FAIL=$nfail"
  [ "$nfail" -eq 0 ] && stageok=$((stageok+1))
  echo "файлы стерео=$f  L=$fL  R=$fR"
done

echo
echo "=================================================================="
echo "итог $REPS запусков при постоянном входе:"
echo "живых:  $alive  (громче слот1/R: $loudR, слот0/L: $loudL)"
echo "рельс:  $rail"
echo "мёртво: $dead"
echo "стадии без FAIL во всех захватах: $stageok/$REPS"
echo "критерий v3 (вход постоянный): рельс=0 И мёртво=0, все живые в ОДНОМ слоте,"
echo "а p90 живого слота примерно один на все запуски (без спутников ×2/×0.5)."
echo "Скачет L<->R или p90 гуляет лесенкой ×2 это фаза ещё случайна (v3 не сработал)."
echo "Строки 'not SCLK-synced' в логе выше = поллинг RX по таймауту, фаза не синхронизирована."
echo "файлы результатов (стерео + моно L/R, слушать aplay):"
for i in $(seq 1 "$REPS"); do echo "$OUT/r$i.wav  $OUT/r${i}_L.wav  $OUT/r${i}_R.wav"; done
dmesg 2>/dev/null | tail -n +$((RUN0+1)) > "$OUT/dmesg-run.log"
echo "полный dmesg прогона (если фильтр что-то упустил): $OUT/dmesg-run.log"
echo "=================================================================="
