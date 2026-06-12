#!/bin/bash
# TIER1 диагностика захвата (внутренний ADC, card0 dev0) LicheeRV Nano.
# Запускать на УЖЕ прошитом образе B по SSH/UART. Перепрошивка НЕ нужна.
# Источник речи держать ~50 см от микрофона на плате весь прогон.
# На выходе: полный дамп микшера, регистры ADC (в т.ч. mute ANA2),
# пер-канальный peak/rms сырого стерео, и свип gain/rate/device.
set -u
CARD=0
OUT=/tmp/tier1_audio
ADC_BASE=0x0300A100          # sound_adc reg base (из cv180x.dtsi)
mkdir -p "$OUT"
echo "=================================================================="
echo " TIER1 audio capture diagnostics (образ B, без перепрошивки)"
echo " Держи речь ~50 см от мика весь прогон."
echo "=================================================================="

# ---- 0. окружение ------------------------------------------------------
echo; echo "### kernel / alsa ###"
uname -a
cat /proc/asound/cards 2>/dev/null
echo "--- dmesg audio tail ---"
dmesg | grep -iE 'cv1800b|rxadc|i2s|sound|mclk|hw_params' | tail -n 30

# ---- 1. ПОЛНЫЙ дамп микшера (ищем скрытый digital vol/mute/boost) ------
echo; echo "### amixer -c $CARD contents (FULL) ###"
amixer -c "$CARD" contents
echo "### amixer -c $CARD scontrols ###"
amixer -c "$CARD" scontrols

# ---- метрика: python3 (stdlib wave), иначе sox, иначе размер ----------
HAVE_PY=0; HAVE_SOX=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1
command -v sox     >/dev/null 2>&1 && HAVE_SOX=1
echo; echo "metric backend: python3=$HAVE_PY sox=$HAVE_SOX"

cat > "$OUT/metric.py" <<'PYEOF'
import sys, wave, struct, math
fn = sys.argv[1]
w = wave.open(fn, 'rb')
ch = w.getnchannels(); sw = w.getsampwidth(); n = w.getnframes(); sr = w.getframerate()
data = w.readframes(n); w.close()
if sw != 2:
    print("  [skip] sampwidth=%d (need 16-bit)" % sw); sys.exit(0)
total = len(data)//2
s = struct.unpack("<%dh" % total, data[:total*2])
peaks=[0]*ch; sq=[0.0]*ch; cnt=[0]*ch
for i,v in enumerate(s):
    c=i%ch; a=abs(v)
    if a>peaks[c]: peaks[c]=a
    sq[c]+=v*v; cnt[c]+=1
print("  file=%s ch=%d rate=%d frames=%d" % (fn,ch,sr,n))
for c in range(ch):
    rms = math.sqrt(sq[c]/cnt[c]) if cnt[c] else 0.0
    pk  = peaks[c]
    vu  = 100.0*pk/32768.0
    dbfs= (20*math.log10(pk/32768.0)) if pk>0 else float('-inf')
    print("    ch%d: peak=%6d (%.1f%% VU, %.1f dBFS)  rms=%9.1f" % (c,pk,vu,dbfs,rms))
PYEOF

# дамп регистров ADC через /dev/mem (читает live-состояние, в т.ч. mute ANA2)
cat > "$OUT/regdump.py" <<'PYEOF'
import mmap, os, struct, sys
BASE = int(sys.argv[1], 16)
PAGE = 0x1000
pa = BASE & ~(PAGE-1)
off = BASE - pa
regs = [("CTRL0",0x00),("CTRL1",0x04),("STATUS",0x08),("CLK",0x0c),
        ("ANA0",0x10),("ANA1",0x14),("ANA2",0x18),("ANA3",0x1c),("ANA4",0x20)]
try:
    fd = os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
except Exception as e:
    print("  [/dev/mem недоступен: %s]" % e); sys.exit(0)
try:
    m = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=pa)
except Exception as e:
    print("  [mmap не удался (STRICT_DEVMEM?): %s]" % e); os.close(fd); sys.exit(0)
def r(o): return struct.unpack("<I", m[off+o:off+o+4])[0]
for name,o in regs:
    print("  %-7s @0x%08x = 0x%08x" % (name, BASE+o, r(o)))
ana2 = r(0x18)
print("  -> ANA2 MUTEL[0]=%d  MUTER[1]=%d   (1 = ПРИГЛУШЕН!)" % (ana2 & 1, (ana2>>1) & 1))
ana0 = r(0x10)
print("  -> ANA0 left=0x%04x right=0x%04x" % (ana0 & 0xFFFF, (ana0>>16) & 0xFFFF))
ana3 = r(0x1c)
print("  -> ANA3 CTUNE[11:8]=0x%x" % ((ana3>>8) & 0xF))
m.close(); os.close(fd)
PYEOF

metric() {  # $1 = wav
  if [ "$HAVE_PY" = "1" ]; then python3 "$OUT/metric.py" "$1"
  elif [ "$HAVE_SOX" = "1" ]; then sox "$1" -n stat 2>&1 | grep -iE 'Maximum amplitude|RMS amplitude'
  else echo "  [нет metric tool] file=$1 size=$(wc -c < "$1") bytes"; fi
}
set_gain() { amixer -c "$CARD" cset numid=1 "$1",0 >/dev/null 2>&1; }

# временный asound с include базового конфига (иначе mic_l не резолвится)
ALSA_BASE=/usr/share/alsa/alsa.conf
{
  [ -f "$ALSA_BASE" ] && echo "<$ALSA_BASE>"
  echo 'pcm.mic_l { type plug ; slave.pcm "hw:0,0" ; slave.channels 2 ; ttable.0.0 1.0 }'
} > "$OUT/asound.tmp"
rec_left() {  # $1=rate $2=out  -> только левый канал; fallback plughw
  ALSA_CONFIG_PATH="$OUT/asound.tmp" arecord -D mic_l -f S16_LE -r "$1" -c 1 -d 5 "$2" 2>/dev/null \
    || arecord -D plughw:${CARD},0 -f S16_LE -r "$1" -c 1 -d 5 "$2" 2>/dev/null
}

# ---- 2. регистры ADC во время ЖИВОГО захвата (mute-бит ANA2!) ----------
echo; echo "=================================================================="
echo "### 2. регистры ADC @gain=24 во время активного захвата ###"
set_gain 24
arecord -D hw:${CARD},0 -f S16_LE -r 48000 -c 2 -d 3 "$OUT/.probe.wav" >/dev/null 2>&1 &
APID=$!
sleep 1
python3 "$OUT/regdump.py" "$ADC_BASE"
wait $APID 2>/dev/null

# ---- 3. СЫРОЕ СТЕРЕО @max gain: мик на левом? насколько тих? -----------
echo; echo "=================================================================="
echo "### 3. RAW STEREO hw:${CARD},0 -c 2 @48000, gain=24 (+48dB), 5 c ###"
echo "    ch0 = левый (мик),  ch1 = правый (висящий вход -> шум)"
set_gain 24
arecord -D hw:${CARD},0 -f S16_LE -r 48000 -c 2 -d 5 "$OUT/raw_g24_48k_stereo.wav" 2>/dev/null
metric "$OUT/raw_g24_48k_stereo.wav"

# ---- 4. свип GAIN (моно левый) -----------------------------------------
echo; echo "=================================================================="
echo "### 4. GAIN sweep, моно левый @48000, 5 c каждый ###"
for g in 18 22 24; do
  echo "--- gain=$g ---"; set_gain "$g"
  rec_left 48000 "$OUT/mic_g${g}_48k.wav"; metric "$OUT/mic_g${g}_48k.wav"
done

# ---- 5. свип RATE @gain 24 ---------------------------------------------
echo; echo "=================================================================="
echo "### 5. RATE sweep @gain=24, моно левый, 5 c каждый ###"
set_gain 24
for r in 16000 48000; do
  echo "--- rate=$r ---"; rec_left "$r" "$OUT/mic_g24_${r}.wav"; metric "$OUT/mic_g24_${r}.wav"
done

# ---- 6. свип DEVICE @gain 24 -------------------------------------------
echo; echo "=================================================================="
echo "### 6. DEVICE sweep @gain=24, 48000, 5 c каждый ###"
set_gain 24
echo "--- hw:${CARD},0 (raw 2ch) ---"
arecord -D hw:${CARD},0 -f S16_LE -r 48000 -c 2 -d 5 "$OUT/dev_hw.wav" 2>/dev/null; metric "$OUT/dev_hw.wav"
echo "--- plughw:${CARD},0 mono ---"
arecord -D plughw:${CARD},0 -f S16_LE -r 48000 -c 1 -d 5 "$OUT/dev_plughw.wav" 2>/dev/null; metric "$OUT/dev_plughw.wav"
echo "--- mic_l route (левый) ---"
rec_left 48000 "$OUT/dev_route.wav"; metric "$OUT/dev_route.wav"

# ---- 7. финал: cget numid=1 + dmesg hw_params --------------------------
echo; echo "=================================================================="
echo "### 7. финальное состояние numid=1 + dmesg hw_params ###"
amixer -c "$CARD" cget numid=1
dmesg | grep -iE 'adc hw_params' | tail -n 8
echo
echo "WAV-файлы для оффлайн-прослушки/scp:"; ls -la "$OUT"/*.wav 2>/dev/null
echo "=================================================================="
echo " ГОТОВО. Пришли весь вывод целиком."
echo " Смотреть: секц.2 ANA2 MUTEL; секц.3 ch0 vs ch1; секц.4-6 какой рецепт громче."
echo "=================================================================="
