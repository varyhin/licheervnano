# Аппаратный тест записи (capture) LicheeRV Nano

Методика детальной проверки захвата внутреннего микрофона по ступеням
чувствительности (PGA gain) и уровню сигнала. Сворачивает дорогой ручной
тест в один пастимый прогон. Анализатор не зависит от наличия python/sox на
плате (только `od`+`awk`).

Статус: пройдено на железе E 2026-06-13 на vendor-faithful сборке (kernel
`#1 SMP Sat Jun 13 22:27 MSK 2026`, release `d77741c2`). Захват чистый и
монотонный, диапазон PGA +48 dB цел, правый вход молчит, gain 20 стабилен.

## 0. Сверка образа перед тестом

Сначала убедиться, что загружена именно проверяемая сборка (иначе тест
бессмысленен, эта ошибка уже случалась с прошлой прошивкой):

```sh
uname -a                            # дата сборки ядра
cat /etc/licheervnano-release       # commit + время сборки
arecord -l                          # card 0 device 0 = cv1800b-i2s-adc-hifi
amixer -c0 contents                 # numid=1 'Internal I2S Capture Volume' 0..24
```

## 1. Анализатор (вставить один раз в сессию)

Считает по стерео S16_LE WAV для L и R: peak, rms, DC, число клиппов.

```sh
an() {
  tail -c +45 "$1" | od -An -v -td2 -w4 | awk '
    {n++; l=$1; r=$2; al=l<0?-l:l; ar=r<0?-r:r;
     if(al>pl)pl=al; if(ar>pr)pr=ar; sl+=l*l; sr+=r*r; dl+=l; dr+=r;
     if(al>=32767)cl++; if(ar>=32767)cr++}
    END{ if(!n){print "пусто"; exit}
      printf "L peak=%5d(%3.0f%%) rms=%5.0f dc=%+5.0f clip=%d | R peak=%5d(%3.0f%%) rms=%5.0f dc=%+5.0f clip=%d | n=%d\n",
        pl,100*pl/32768,sqrt(sl/n),dl/n,cl, pr,100*pr/32768,sqrt(sr/n),dr/n,cr, n}'
}
```

## 2. Фазы теста

Запись всегда сырым стерео `hw:0,0 -c2` (моно `-c1` ломает кадр; см.
`audio_setup.md`). Микрофон в ЛЕВОМ слоте, правый вход висит.

Фаза A, тишина (сидеть тихо): шумовой пол по ступеням + молчание правого +
старт-транзиент.

```sh
for g in 0 8 14 16 18 20 22 24; do
  amixer -c0 cset numid=1 $g,$g >/dev/null
  arecord -D hw:0,0 -c2 -r48000 -fS16_LE -d3 /tmp/q$g.wav >/dev/null 2>&1
  printf "gain %2d тишина: " $g; an /tmp/q$g.wav
done
amixer -c0 cset numid=1 24,24 >/dev/null
arecord -D hw:0,0 -c2 -r48000 -fS16_LE -d2 /tmp/start.wav >/dev/null 2>&1
head -c $((44+48000)) /tmp/start.wav > /tmp/h.wav
printf "старт 0.25с: "; an /tmp/h.wav
printf "весь 2с:     "; an /tmp/start.wav
```

Фаза B, речь (говорить ровно всю запись, фикс дистанция): свип чувствительности.

```sh
for g in 8 14 16 18 20 22 24; do
  amixer -c0 cset numid=1 $g,$g >/dev/null
  echo ">>> gain $g, говори 4с"; sleep 1
  arecord -D hw:0,0 -c2 -r48000 -fS16_LE -d4 /tmp/s$g.wav >/dev/null 2>&1
  printf "gain %2d речь: " $g; an /tmp/s$g.wav
done
```

Фаза C, стабильность подозрительных ступеней (gain 20 исторически нестабилен):

```sh
for g in 20 24; do for t in 1 2 3; do
  amixer -c0 cset numid=1 $g,$g >/dev/null
  arecord -D hw:0,0 -c2 -r48000 -fS16_LE -d3 /tmp/r${g}_$t.wav >/dev/null 2>&1
  printf "gain %2d try %d: " $g $t; an /tmp/r${g}_$t.wav
done; done
```

Фаза D, слух и питч:

```sh
amixer -c0 cset numid=1 18,0 >/dev/null
arecord -D plughw:0,0 -c1 -r48000 -fS16_LE -d5 /tmp/mono.wav
aplay -D plughw:0,1 /tmp/mono.wav
```

## 3. Критерии прохождения

- L rms растёт монотонно с gain, без скачков и без застревания на пике
- R = 0 (peak/rms) на всех gain (висящий правый вход молчит после settle)
- clip = 0 везде на нормальном входе
- старт-транзиент: пик первых 0.25с не выше хвоста (settle гасит DC висящего входа)
- gain 20 стабилен от прогона к прогону (нет тишины rms~0, нет railing peak≈32767)
- на слух: голос разборчив, без щелчков, питч нормальный (замедленный/басовитый = кадр поломан, BCLK расходится)

## 4. Эталонные числа (2026-06-13, vendor-faithful, release d77741c2)

Тишина (шумовой пол, характеризует лестницу gain, не зависит от акустики):

| gain | L peak | L rms | R |
|---|---|---|---|
| 0  | 15   | 3   | 0 |
| 8  | 87   | 21  | 0 |
| 14 | 334  | 83  | 0 |
| 16 | 505  | 130 | 0 |
| 18 | 829  | 199 | 0 |
| 20 | 1290 | 311 | 0 |
| 22 | 1937 | 467 | 0 |
| 24 | 3580 | 737 | 0 |

Диапазон gain0→gain24 это rms 3→737 = +47.8 dB, ровно спека PGA 0..+48 dB.

gain 20 в 6 прогонах: peak 1735..2376, rms 355..471, clip 0, R 0 (стабилен).
Громкая близкая речь на gain 24: peak 32% (10547), rms 1773, clip 0.

Абсолютный уровень речи зависит от громкости голоса и дистанции, поэтому
таблица речи в `audio_setup.md` это пример одной сессии, а не калибровка.

## 5. Громкость записи упёрта в аналоговый потолок

Аналоговый PGA максимум +48 dB (gain 24). Даже громко и близко пик ~32%,
rms ~5%. Это потолок тракта, не настройка. Громче только цифровым makeup
(постобработка ×2-3 безопасна по запасу) или ALSA `softvol`-плагином на
capture, оба усиливают и шум. См. раздел про уровень в `audio_setup.md`.

## Связанные документы

- `docs/audio_setup.md` это полный bring-up аудио (тракт, регистры, рецепты ALSA)
