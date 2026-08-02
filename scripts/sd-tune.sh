#!/bin/sh
# Подбор параметров блочной очереди microSD на LicheeRV Nano. Запускается на
# плате от root, меняет только sysfs и возвращает исходные значения на выходе,
# в том числе по Ctrl-C. Ничего не пишет на карту.
#
# Меряется буферизованное чтение со сбросом кэша, потому что read_ahead_kb на
# путь O_DIRECT не влияет вообще: sd-bench.sh с iflag=direct показывает такт
# шины, а здесь нужен именно тот путь, которым читают файлы.
#
# Два этапа:
#   A. планировщик как есть, перебор read_ahead_kb, один поток
#   B. лучший read_ahead_kb, перебор планировщиков, один поток и два потока
#
# Два потока нужны потому, что планировщик проявляется на конкуренции, а не на
# одиночном последовательном чтении.
#
# Использование:
#   ./sd-tune.sh              полный подбор (около трёх минут)
#   SIZE_MB=64 ./sd-tune.sh   короче и грубее (по умолчанию 128)
#   DEV=mmcblk0 ./sd-tune.sh  другое устройство

LC_ALL=C
export LC_ALL

dev="${DEV:-mmcblk0}"
size_mb="${SIZE_MB:-128}"
q="/sys/block/$dev/queue"

if [ "$(id -u)" -ne 0 ]; then
	echo "нужен root: drop_caches и запись в sysfs очереди"
	exit 1
fi

if [ ! -d "$q" ]; then
	echo "нет $q"
	exit 1
fi

orig_ra=$(cat $q/read_ahead_kb)
orig_sched=$(sed -e 's/.*\[//' -e 's/\].*//' $q/scheduler)

restore() {
	echo "$orig_ra" > $q/read_ahead_kb 2>/dev/null
	echo "$orig_sched" > $q/scheduler 2>/dev/null
	echo
	echo "исходные значения возвращены: read_ahead_kb=$orig_ra scheduler=$orig_sched"
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

# read_one -> МБ/с одним потоком, буферизованно, с холодного кэша
read_one() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
	dd if=/dev/$dev of=/dev/null bs=1M count="$size_mb" 2>&1 | tail -1 |
		awk -F, '{ gsub(/^ +/, "", $NF); sub(/ MB\/s/, "", $NF); print $NF }'
}

# read_two -> суммарные МБ/с двумя потоками с разных участков карты
read_two() {
	half=$(( size_mb / 2 ))
	sync
	echo 3 > /proc/sys/vm/drop_caches
	t0=$(date +%s%N)
	dd if=/dev/$dev of=/dev/null bs=1M count="$half" skip=0 2>/dev/null &
	p1=$!
	dd if=/dev/$dev of=/dev/null bs=1M count="$half" skip=4096 2>/dev/null &
	p2=$!
	wait $p1 $p2
	t1=$(date +%s%N)
	awk -v b="$(( half * 2 ))" -v ns="$(( t1 - t0 ))" \
		'BEGIN { printf "%.1f", b / (ns / 1000000000) }'
}

# best_of ФУНКЦИЯ -> лучший из двух прогонов, чтобы сбить шум
best_of() {
	a=$($1)
	b=$($1)
	awk -v x="$a" -v y="$b" 'BEGIN { printf "%.1f", (x > y ? x : y) }'
}

echo "== исходное состояние =="
echo "  устройство      /dev/$dev"
echo "  read_ahead_kb   $orig_ra"
echo "  scheduler       $orig_sched"
echo "  доступные       $(tr -d '[]' < $q/scheduler)"
echo "  объём теста     ${size_mb} МБ"

base=$(best_of read_one)
echo "  базовое чтение  $base МБ/с"

echo
echo "== этап A: read_ahead_kb, планировщик $orig_sched, один поток =="
best_ra=""
best_ra_val=0
for ra in 128 256 512 1024; do
	echo "$ra" > $q/read_ahead_kb
	v=$(best_of read_one)
	printf "  %-6s КБ  %s МБ/с\n" "$ra" "$v"
	gt=$(awk -v a="$v" -v b="$best_ra_val" 'BEGIN { print (a > b) ? 1 : 0 }')
	[ "$gt" -eq 1 ] && { best_ra="$ra"; best_ra_val="$v"; }
done
echo "  лучший read_ahead_kb: $best_ra ($best_ra_val МБ/с)"

echo
echo "== этап B: планировщик, read_ahead_kb $best_ra =="
echo "$best_ra" > $q/read_ahead_kb
for s in $(tr -d '[]' < $q/scheduler); do
	echo "$s" > $q/scheduler 2>/dev/null || continue
	v1=$(best_of read_one)
	v2=$(best_of read_two)
	printf "  %-12s один поток %s МБ/с, два потока %s МБ/с\n" "$s" "$v1" "$v2"
done

echo
echo "== итог =="
echo "  базовое чтение при read_ahead_kb=$orig_ra scheduler=$orig_sched: $base МБ/с"
echo "  лучший read_ahead_kb по этапу A: $best_ra"
echo "  прирост от readahead: $(awk -v a="$best_ra_val" -v b="$base" \
	'BEGIN { if (b > 0) printf "%.1f%%", (a - b) / b * 100; else print "нет данных" }')"
echo "  планировщик выбирать по числу для двух потоков, на одном потоке"
echo "  разницы обычно нет"
echo "  разброс между прогонами на SD в пределах 5% это шум, а не эффект"
