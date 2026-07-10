#!/bin/sh
# Проверка Wi-Fi на LicheeRV Nano W/WE. Запускается на плате, печатает
# PASS/FAIL по каждому пункту и суммарный ИТОГ, код возврата 0 = PASS.
#
# Покрывает обе ревизии платы W, они несут разные радиомодули:
#   AIC8801     (SDIO 5449:0145) -> firmware комплекта aic8800_u03
#   AIC8800D80  (SDIO C8A1:0082) -> firmware комплекта aic8800d80_u02
# Чип определяется по dmesg, а не по маркировке на модуле.
#
# Типовой отказ при отсутствующем комплекте firmware: SDIO энумерируется,
# aic8800_bsp грузится, затем aicbt_patch_table_alloc fail -> откат ->
# set power on fail, fdrv не биндится, wlan0 нет.
#
# Использование:
#   ./check-wifi.sh              проверить всё, метку релиза не сверять
#   ./check-wifi.sh 6778e152     дополнительно сверить /etc/licheervnano-release
#
# Сверка метки нужна, чтобы не тестировать карту с прошлой прошивкой.

expected_rel="$1"
fail=0

check() {
	# check "описание" "фактическое" "ожидаемое"
	if [ "$2" = "$3" ]; then
		echo "  PASS $1 ($2)"
	else
		echo "  FAIL $1: получено «$2», ожидалось «$3»"
		fail=1
	fi
}

echo "== идентичность прошитого образа =="
rel=$(cat /etc/licheervnano-release 2>/dev/null || echo "нет файла")
echo "  $rel"
if [ -n "$expected_rel" ]; then
	if echo "$rel" | grep -q "$expected_rel"; then
		echo "  PASS метка содержит $expected_rel"
	else
		echo "  FAIL прошита не та карта, ожидался $expected_rel"
		fail=1
	fi
else
	echo "  (метка не сверялась, аргумент не задан)"
fi

echo "== вариант платы =="
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
case "$model" in
	"LicheeRV Nano W"|"LicheeRV Nano WE")
		echo "  PASS загружен вариант с Wi-Fi ($model)" ;;
	*)
		echo "  FAIL вариант без Wi-Fi ($model), выбрать nano-w или nano-we в extlinux"
		fail=1 ;;
esac

echo "== радиомодуль =="
chip=$(dmesg | grep -o 'USE AIC8800D80\|USE AIC8801' | head -1)
if [ -n "$chip" ]; then
	echo "  PASS чип распознан ($chip)"
else
	echo "  FAIL чип не распознан, aic8800_bsp не дошёл до chipmatch"
	fail=1
fi

echo "== загрузка firmware =="
check "нет aicbt_patch_table_alloc fail" \
	"$(dmesg | grep -c 'aicbt_patch_table_alloc fail')" "0"
check "нет set power on fail" \
	"$(dmesg | grep -c 'set power on fail')" "0"
check "нет таймаута power-on (-110)" \
	"$(dmesg | grep -c 'failed with error -110')" "0"

echo "== драйвер и интерфейс =="
check "aic8800_fdrv загружен" "$(lsmod | grep -c '^aic8800_fdrv')" "1"
if [ -d /sys/class/net/wlan0 ]; then
	echo "  PASS wlan0 существует"
else
	echo "  FAIL wlan0 отсутствует"
	fail=1
fi

echo "== эфир =="
ip link set wlan0 up 2>/dev/null
nets=$(iw dev wlan0 scan 2>/dev/null | grep -c '^BSS')
if [ "$nets" -gt 0 ]; then
	echo "  PASS чип видит сети ($nets)"
else
	echo "  FAIL скан пуст, радио не принимает beacon"
	fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "ИТОГ: PASS"
else
	echo "ИТОГ: FAIL"
fi
exit "$fail"
