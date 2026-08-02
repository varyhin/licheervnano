#!/bin/sh
# Замер тракта microSD и SDIO на LicheeRV Nano. Запускается на плате от root.
#
# Отвечает на один вопрос: какой такт реально идёт на шину и совпадает ли он
# с тем, что думает ядро. Ядро берёт базовый такт SDHCI из клока с именем
# "core" в узле mmc, а в cv180x.dtsi это CLK_AXI4_SD0 (ветка clk_axi4,
# fpll/5 = 300 МГц). Реальный источник такта карты это clk_sd0 (fpll/15 =
# 100 МГц, TRM таблица 8.4). Если имена в DT перепутаны, все программируемые
# частоты втрое ниже заказанных, а отказа нет, потому что такт идентификации
# 133 кГц всё ещё попадает в допустимое окно 100-400 кГц.
#
# Гипотеза подтверждена, если такт по регистрам ровно втрое ниже такта по
# мнению ядра. Гипотеза опровергнута, если они совпадают.
#
# Использование:
#   ./sd-bench.sh                 полный замер
#   ./sd-bench.sh 7932a240        дополнительно сверить /etc/licheervnano-release
#   SKIP_WRITE=1 ./sd-bench.sh    без теста записи
#   SIZE_MB=256 ./sd-bench.sh     объём последовательного чтения (по умолчанию 128)
#
# Читает регистры через /dev/mem, пишет только временный файл в корне и
# удаляет его. Сырое устройство только читается.

LC_ALL=C
export LC_ALL

expected_rel="$1"
size_mb="${SIZE_MB:-128}"
osc_hz=25000000

CLK_BASE=0x03002000
REG_CLK_EN_0=0x03002000
REG_CLK_BYP_0=0x03002030
REG_DIV_CLK_SD0=0x03002070
REG_DIV_CLK_SD1=0x0300207c
REG_DIV_CLK_AXI4=0x030020b8
REG_FPLL_CSR=0x03002910

if [ "$(id -u)" -ne 0 ]; then
	echo "нужен root: /dev/mem, drop_caches и чтение сырого устройства"
	exit 1
fi

if ! command -v busybox >/dev/null 2>&1; then
	echo "нет busybox, нечем читать регистры (apt install busybox)"
	exit 1
fi

[ -d /sys/kernel/debug/clk ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null

# read32 АДРЕС -> десятичное значение регистра
read32() {
	v=$(busybox devmem "$1" 32 2>/dev/null)
	[ -n "$v" ] || { echo 0; return 1; }
	echo $(( v ))
}

# mhz ГЕРЦЫ -> строка вида "16.67 МГц"
mhz() {
	awk -v h="$1" 'BEGIN { printf "%.2f МГц", h / 1000000 }'
}

echo "== идентичность прошитого образа =="
rel=$(cat /etc/licheervnano-release 2>/dev/null || echo "нет файла")
echo "  $rel"
echo "  $(uname -r)  $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
if [ -n "$expected_rel" ]; then
	if echo "$rel" | grep -q "$expected_rel"; then
		echo "  PASS метка содержит $expected_rel"
	else
		echo "  FAIL прошита не та карта, ожидался $expected_rel"
		exit 1
	fi
fi

echo
echo "== дерево тактов, регистры =="
fpll_csr=$(read32 $REG_FPLL_CSR)
pre_div=$(( fpll_csr & 0x7f ))
post_div=$(( (fpll_csr >> 8) & 0x7f ))
pll_div=$(( (fpll_csr >> 17) & 0x7f ))
[ "$pre_div" -gt 0 ] || pre_div=1
[ "$post_div" -gt 0 ] || post_div=1
fpll_hz=$(( osc_hz * pll_div / (pre_div * post_div) ))
printf "  fpll_csr      0x%08x  pre %d post %d div %d  ->  %s\n" \
	"$fpll_csr" "$pre_div" "$post_div" "$pll_div" "$(mhz $fpll_hz)"

clk_en_0=$(read32 $REG_CLK_EN_0)
clk_byp_0=$(read32 $REG_CLK_BYP_0)
printf "  clk_en_0      0x%08x  axi4_sd0 %d sd0 %d axi4_sd1 %d sd1 %d\n" \
	"$clk_en_0" $(( (clk_en_0 >> 18) & 1 )) $(( (clk_en_0 >> 19) & 1 )) \
	$(( (clk_en_0 >> 21) & 1 )) $(( (clk_en_0 >> 22) & 1 ))
printf "  clk_byp_0     0x%08x  байпас sd0 %d sd1 %d\n" \
	"$clk_byp_0" $(( (clk_byp_0 >> 6) & 1 )) $(( (clk_byp_0 >> 7) & 1 ))

# src_clk РЕГИСТР_ДЕЛИТЕЛЯ БИТ_БАЙПАСА -> частота источника такта карты в Гц
src_clk() {
	raw=$(read32 "$1")
	byp=$(( (clk_byp_0 >> $2) & 1 ))
	if [ "$byp" -eq 1 ]; then
		echo "$osc_hz"
		return
	fi
	if [ $(( (raw >> 3) & 1 )) -eq 1 ]; then
		d=$(( (raw >> 16) & 0x1f ))
	else
		d=15
	fi
	[ "$d" -gt 0 ] || d=1
	echo $(( fpll_hz / d ))
}

div_sd0=$(read32 $REG_DIV_CLK_SD0)
div_sd1=$(read32 $REG_DIV_CLK_SD1)
div_axi4=$(read32 $REG_DIV_CLK_AXI4)
clk_sd0=$(src_clk $REG_DIV_CLK_SD0 6)
clk_sd1=$(src_clk $REG_DIV_CLK_SD1 7)
if [ $(( (div_axi4 >> 3) & 1 )) -eq 1 ]; then
	d_axi4=$(( (div_axi4 >> 16) & 0xf ))
else
	d_axi4=5
fi
[ "$d_axi4" -gt 0 ] || d_axi4=1
clk_axi4=$(( fpll_hz / d_axi4 ))

printf "  div_clk_sd0   0x%08x  ->  clk_sd0  = %s\n" "$div_sd0" "$(mhz $clk_sd0)"
printf "  div_clk_sd1   0x%08x  ->  clk_sd1  = %s\n" "$div_sd1" "$(mhz $clk_sd1)"
printf "  div_clk_axi4  0x%08x  ->  clk_axi4 = %s (он же clk_axi4_sd0/sd1)\n" \
	"$div_axi4" "$(mhz $clk_axi4)"

echo
echo "== то же по мнению clk-фреймворка =="
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
	awk '$1 ~ /^(clk_axi4|clk_axi4_sd0|clk_axi4_sd1|clk_sd0|clk_sd1|clk_fpll)$/ \
		{ printf "  %-16s %s Гц\n", $1, $5 }' /sys/kernel/debug/clk/clk_summary
else
	echo "  нет /sys/kernel/debug/clk/clk_summary"
fi

verdict_lines=""
passport=""

# probe_host АДРЕС_БАЗЫ ЧАСТОТА_ИСТОЧНИКА ПОДПИСЬ
probe_host() {
	base="$1"
	src="$2"
	label="$3"
	tag=$(printf "%x" "$base")

	idx=""
	for h in /sys/class/mmc_host/mmc*; do
		[ -e "$h" ] || continue
		d=$(readlink -f "$h/device" 2>/dev/null)
		case "$(basename "$d")" in
			"$tag".mmc|"$tag".sdhci) idx=$(basename "$h") ;;
		esac
	done

	echo
	echo "== $label, контроллер $tag =="
	if [ -z "$idx" ]; then
		echo "  контроллер не поднят ядром, пропуск"
		return
	fi

	present=$(read32 $(( base + 0x24 )))
	cc32=$(read32 $(( base + 0x2c )))
	hc2=$(read32 $(( base + 0x3c )))
	caps=$(read32 $(( base + 0x40 )))
	caps1=$(read32 $(( base + 0x44 )))

	cc=$(( cc32 & 0xffff ))
	n=$(( ((cc >> 8) & 0xff) | (((cc >> 6) & 0x3) << 8) ))
	if [ "$n" -eq 0 ]; then
		real_div=1
	else
		real_div=$(( 2 * n ))
	fi
	real_hz=$(( src / real_div ))
	clk_mul=$(( (caps1 >> 16) & 0xff ))
	cap_base=$(( (caps >> 8) & 0xff ))

	printf "  Present State 0x%08x  карта вставлена %d\n" \
		"$present" $(( (present >> 16) & 1 ))
	printf "  Clock Control 0x%04x      делитель N=%d  ->  такт /%d\n" \
		"$cc" "$n" "$real_div"
	printf "  Host Control2 0x%04x      1.8V signaling %d  UHS mode %d\n" \
		$(( (hc2 >> 16) & 0xffff )) $(( (hc2 >> 19) & 1 )) $(( (hc2 >> 16) & 0x7 ))
	printf "  Capabilities  0x%08x  заявленный базовый такт %d МГц\n" "$caps" "$cap_base"
	printf "  Capabilities1 0x%08x  clock multiplier %d\n" "$caps1" "$clk_mul"
	[ "$clk_mul" -eq 0 ] || echo "  ВНИМАНИЕ clock multiplier не нулевой, арифметика делителя другая"

	ios=/sys/kernel/debug/$idx/ios
	believed=""
	if [ -r "$ios" ]; then
		believed=$(awk -F'[\t ]+' '/^actual clock:/ { print $3 }' "$ios")
		echo "  ios: $(awk -F'\t+' '/^(clock|actual clock|bus width|timing spec|signal voltage):/ \
			{ printf "%s %s; ", $1, $2 }' "$ios")"
	fi

	echo "  источник такта по регистрам $(mhz $src)"
	echo "  такт шины по регистрам      $(mhz $real_hz)"
	if [ -n "$believed" ]; then
		echo "  такт шины по мнению ядра    $(mhz $believed)"
		ratio=$(awk -v b="$believed" -v r="$real_hz" 'BEGIN { if (r > 0) printf "%.2f", b / r; else print "0" }')
		echo "  отношение                   ${ratio}x"
		case "$ratio" in
			0.9*|1.0*|1.1*)
				verdict_lines="$verdict_lines
  $label: СХОДИТСЯ, ядро и регистры дают один такт (${ratio}x)" ;;
			*)
				verdict_lines="$verdict_lines
  $label: ПЕРЕКОС ${ratio}x, шина идёт на $(mhz $real_hz) вместо $(mhz $believed)" ;;
		esac
	fi

	ceil=$(awk -v h="$real_hz" 'BEGIN { printf "%.1f", h / 2 / 1000000 }')
	echo "  потолок шины при 4 битах    $ceil МБ/с"

	blk=""
	for b in /sys/class/mmc_host/$idx/$idx:*/block/*; do
		[ -e "$b" ] && blk=$(basename "$b")
	done
	[ -n "$blk" ] && echo "  блочное устройство          /dev/$blk"
	HOST_BLK="$blk"
	HOST_REAL_HZ="$real_hz"
	HOST_CEIL="$ceil"
}

HOST_BLK=""
probe_host 0x04310000 "$clk_sd0" "microSD"
sd_blk="$HOST_BLK"
sd_real_hz="$HOST_REAL_HZ"
sd_ceil="$HOST_CEIL"
probe_host 0x04320000 "$clk_sd1" "SDIO Wi-Fi"
sdio_real_hz="$HOST_REAL_HZ"

echo
echo "== карта и параметры очереди =="
if [ -n "$sd_blk" ]; then
	dev="/dev/$sd_blk"
	q="/sys/block/$sd_blk/queue"
	name=$(cat /sys/block/$sd_blk/device/name 2>/dev/null)
	size=$(awk -v s="$(cat /sys/block/$sd_blk/size 2>/dev/null)" 'BEGIN { printf "%.1f ГБ", s * 512 / 1000000000 }')
	echo "  карта      $name  $size"
	echo "  scheduler  $(cat $q/scheduler 2>/dev/null)"
	echo "  read_ahead $(cat $q/read_ahead_kb 2>/dev/null) КБ, max_sectors $(cat $q/max_sectors_kb 2>/dev/null) КБ, nr_requests $(cat $q/nr_requests 2>/dev/null)"
	echo "  discard    $(cat $q/discard_max_bytes 2>/dev/null) байт"
else
	echo "  блочное устройство microSD не найдено, бенчмарк пропущен"
fi

echo
echo "== dmesg по mmc =="
dmesg | grep -iE "mmc[0-9]|sdhci" | head -20 | sed 's/^/  /'

echo
echo "== радиомодуль на SDIO =="
chip=$(dmesg | grep -o 'USE AIC8800D80\|USE AIC8801' | head -1)
echo "  чип        ${chip:-не определён}"
echo "  запрос драйвера: $(dmesg | grep -o 'Set SDIO Clock [0-9]* MHz' | tail -1)"
echo "  (AIC8801 просит 25 МГц, AIC8800D80 просит 150 МГц, зажим по"
echo "   max-frequency узла sdhci1 добавлен в patches/aic8800-vendor/0005)"

bench_read() {
	# bench_read УСТРОЙСТВО БЛОК СЧЁТ -> печатает только скорость
	sync
	echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
	dd if="$1" of=/dev/null bs="$2" count="$3" iflag=direct 2>&1 | tail -1 |
		awk -F, '{ gsub(/^ +/, "", $NF); print $NF }'
}

if [ -n "$sd_blk" ]; then
	echo
	echo "== пропускная способность =="
	r_seq=$(bench_read "/dev/$sd_blk" 1M "$size_mb")
	printf "  %-28s %s\n" "чтение ${size_mb} МБ блоком 1 МБ" "$r_seq"
	r_4k=$(bench_read "/dev/$sd_blk" 4k 4096)
	printf "  %-28s %s\n" "чтение 16 МБ блоком 4 КБ" "$r_4k"

	if [ -z "$SKIP_WRITE" ]; then
		free_kb=$(df -Pk / | awk 'NR==2 { print $4 }')
		if [ "$free_kb" -gt 524288 ]; then
			out=$(dd if=/dev/zero of=/sdbench.tmp bs=1M count=64 oflag=direct conv=fsync 2>&1 | tail -1)
			w_seq=$(echo "$out" | awk -F, '{ gsub(/^ +/, "", $NF); print $NF }')
			printf "  %-28s %s\n" "запись 64 МБ блоком 1 МБ" "$w_seq"
			rm -f /sdbench.tmp
			sync
		else
			w_seq="пропущено, мало места"
			echo "  запись пропущена, свободно ${free_kb} КБ"
		fi
	else
		w_seq="пропущено"
	fi

	echo "  потолок шины при текущем такте $sd_ceil МБ/с"
	passport="clk_real=$sd_real_hz read_1m=$r_seq read_4k=$r_4k write_1m=$w_seq sdio_clk=$sdio_real_hz"
fi

echo
echo "== вердикт по гипотезе о базовом такте =="
if [ -n "$verdict_lines" ]; then
	echo "$verdict_lines"
else
	echo "  не удалось сравнить, нет данных ios"
fi

echo
echo "паспорт замера: $passport"
