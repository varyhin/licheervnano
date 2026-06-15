# Подключение к Wi-Fi на LicheeRV Nano W

Краткая инструкция для Wi-Fi на чипе AIC8800D80 (физически AIC8801 U03) + wpa_supplicant + dhclient в Debian 13 на варианте W.

Статус: работает на железе W (2026-06-11), powersave чипа отключён
опцией ps_on=0 (см. «Известные особенности»).

## Переключение варианта E ↔ W на плате

Вариант платы выбирается значением `default` в extlinux-меню на загрузочном разделе (`/dev/mmcblk0p1`). Сменить с E на W прямо из работающей системы:

```
mount /dev/mmcblk0p1 /mnt
sed -i 's/^default .*/default nano-w/' /mnt/extlinux/extlinux.conf
head -3 /mnt/extlinux/extlinux.conf      # проверить строку: default nano-w
sync
umount /mnt
```

Обратно на E это `default nano-e`, на WE это `default nano-we`.

Важно про первый старт W. Не делать `reboot`, а выключить плату, снять питание на 10+ секунд и включить заново. Тёплая перезагрузка из E часто оставляет радио AIC8801 в полузастрявшем состоянии: `aic8800_bsp` грузится, но фаза power-on чипа таймаутит (`-110`), `aic8800_fdrv` не биндится и `wlan0` не появляется. Питание при reboot удерживается, поэтому сбрасывает чип только снятие питания. Полный признак в `dmesg` и причина описаны в «Известные особенности AIC8801».

## Что должно быть до начала

- Boot варианта W из extlinux меню (пункт 4, `label nano-w`, «LicheeRV Nano-W»)
- Модули загружены автоматически через udev (по SDIO-модалиасу чипа `5449:0145`):

```
lsmod | grep aic8800
# aic8800_fdrv   <- WiFi MAC-драйвер, создаёт wlan0
# aic8800_bsp    <- поднимает чип и заливает firmware (used by fdrv)
```

`aic8800_btlpm` это Bluetooth-модуль, на Wi-Fi-загрузке он не нужен и сам не подгружается (SDIO-алиас есть только у `fdrv` и `bsp`). Он появляется только при инициализации BT.

- Интерфейс `wlan0` присутствует:

```
ip link show wlan0
```

Если нет, поднять вручную:

```
modprobe aic8800_fdrv
ip link set wlan0 up
```

Если `modprobe aic8800_fdrv` отвечает `No such device` (ENODEV), а в `lsmod` виден только `aic8800_bsp`, чип завис на фазе power-on (в `dmesg` таймаут `-110` и `set power on fail`). Ручной modprobe тут бесполезен, SDIO-функции normal mode на шине нет. Снять питание на 10+ секунд и включить заново. См. «Переключение варианта E ↔ W» и «Известные особенности AIC8801».

## Базовый конфиг wpa_supplicant

Создать один раз. Файл `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`:

```
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
country=RU
```

`ctrl_interface` нужен чтобы работал `wpa_cli` (управление supplicant из терминала). `update_config=1` разрешает supplicant сохранять изменения через `save_config`. `country=RU` задаёт регуляторный домен для разрешённых каналов.

## Запуск wpa_supplicant

После каждой перезагрузки:

```
killall wpa_supplicant dhclient 2>/dev/null
rm -f /run/wpa_supplicant/wlan0   # на случай если остался от предыдущего запуска
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf -D nl80211
```

Флаг `-B` фон, `-D nl80211` драйвер ядра.

При старте драйвер aic8800 печатает `nl80211: kernel reports: Registration to specific type not supported`. Это безобидный варнинг: supplicant просит подписку на отдельные подтипы management-фреймов, которую драйвер не поддерживает. На ассоциацию и работу STA это не влияет. Признак успешного старта это строка `Successfully initialized wpa_supplicant`.

## Добавление сети через wpa_cli

После старта supplicant конфиг можно менять через `wpa_cli` без перезаписи файла. Шаги одинаковы для всех типов сетей, отличаются только параметры внутри.

### WPA2 Personal (PSK)

```
wpa_cli -i wlan0 add_network            # вернёт номер N (обычно 0)
wpa_cli -i wlan0 set_network 0 ssid '"ИМЯ_СЕТИ"'
wpa_cli -i wlan0 set_network 0 key_mgmt WPA-PSK
wpa_cli -i wlan0 set_network 0 psk '"ПАРОЛЬ"'
wpa_cli -i wlan0 enable_network 0
wpa_cli -i wlan0 select_network 0
wpa_cli -i wlan0 save_config
```

### WPA3 Personal (SAE)

Современные Android-телефоны и роутеры по умолчанию на WPA3. Признак: `key_mgmt=SAE` в результате scan. От WPA2 отличается двумя обязательными параметрами:

- `key_mgmt=SAE`
- `ieee80211w=2` (PMF, Protected Management Frames обязательны)

```
wpa_cli -i wlan0 add_network
wpa_cli -i wlan0 set_network 0 ssid '"ИМЯ_СЕТИ"'
wpa_cli -i wlan0 set_network 0 key_mgmt SAE
wpa_cli -i wlan0 set_network 0 ieee80211w 2
wpa_cli -i wlan0 set_network 0 psk '"ПАРОЛЬ"'
wpa_cli -i wlan0 enable_network 0
wpa_cli -i wlan0 select_network 0
wpa_cli -i wlan0 save_config
```

Важно. Пароль должен быть в кавычках как plain text, не хешированный PSK. Хеш через `wpa_passphrase` подходит только для WPA2-PSK.

### WPA2/WPA3 transition (совместимый режим)

Некоторые точки одновременно отдают WPA2 и WPA3. Тогда `key_mgmt` принимает оба:

```
wpa_cli -i wlan0 set_network 0 key_mgmt 'WPA-PSK SAE'
wpa_cli -i wlan0 set_network 0 ieee80211w 1
```

`ieee80211w=1` означает PMF optional (для WPA2), `=2` PMF required (для WPA3).

### Открытая сеть (без пароля)

```
wpa_cli -i wlan0 add_network
wpa_cli -i wlan0 set_network 0 ssid '"ИМЯ_СЕТИ"'
wpa_cli -i wlan0 set_network 0 key_mgmt NONE
wpa_cli -i wlan0 enable_network 0
wpa_cli -i wlan0 select_network 0
wpa_cli -i wlan0 save_config
```

### Скрытая сеть (SSID не broadcast)

К любой из команд выше добавить:

```
wpa_cli -i wlan0 set_network 0 scan_ssid 1
```

`scan_ssid=1` заставит supplicant отправлять directed probe-request с конкретным SSID вместо пассивного слушания beacon.

## Проверка ассоциации

После `select_network` подождать 8-15 секунд:

```
sleep 10
wpa_cli -i wlan0 status
```

Что хочется увидеть в выводе:

- `wpa_state=COMPLETED` — auth + 4-way handshake прошли
- `ssid=ИМЯ_СЕТИ`
- `bssid=xx:xx:xx:xx:xx:xx`
- `key_mgmt=WPA-PSK` или `SAE`
- `pairwise_cipher=CCMP`
- `wifi_generation=6` для WiFi 6 точек (Wi-Fi 5 покажет `5`, Wi-Fi 4 не показывает)

Если `wpa_state` застрял на `SCANNING` — попробовать `wpa_cli -i wlan0 reconnect`. Если на `ASSOCIATING` или `4WAY_HANDSHAKE` — проверить пароль и `key_mgmt`.

## Получить IP по DHCP

```
dhclient -v wlan0
# или, если установлен busybox: udhcpc -i wlan0
```

Проверка:

```
ip addr show wlan0
ip route
ping -c 4 1.1.1.1
ping -c 4 ya.ru   # проверка DNS
```

## Постоянное подключение на загрузке (автоконнект)

Всё выше поднимает Wi-Fi на один сеанс. После перезагрузки модули встанут сами (udev по SDIO-модалиасу), но `wpa_supplicant` и `dhclient` запускать некому. В образе включён только `wpa_supplicant.service` типа D-Bus, это демон в режиме ожидания, сам он ни к какой сети из файла не подключается. А в `/etc/network/interfaces.d/` есть стойки только для `end0` и `lo`. Чтобы плата поднимала Wi-Fi автоматически, нужны две вещи.

Первое это сеть в конфиге. Пароль и параметры должны лежать в `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` блоком `network={...}`. Его записывает `wpa_cli ... save_config` (при `update_config=1`) либо ручная правка файла. Пароль там в открытом виде, файл стоит закрыть:

```
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

Второе это стойка ifupdown для wlan0. Создать `/etc/network/interfaces.d/wlan0`:

```
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
```

Берётся `allow-hotplug`, а не `auto`. Интерфейс появляется поздно, его создаёт модуль, загружаемый udev. `auto` сработал бы на раннем `ifup -a`, когда `wlan0` ещё нет, и упал бы. `allow-hotplug` ловит именно событие появления интерфейса. udev-правило `80-ifupdown.rules` дёргает `ifup@wlan0`, хук `if-pre-up.d/wpasupplicant` стартует `wpa_supplicant` с указанным конфигом, после ассоциации `dhclient` берёт IP.

Проверить, не перезагружаясь:

```
killall wpa_supplicant dhclient 2>/dev/null
ifup wlan0
ip addr show wlan0      # ждём inet
```

Проверено на железе W (2026-06-15): после холодного `poweroff/poweron` и после обычного `reboot` `wlan0` поднимается сам и получает IP по DHCP без ручных команд.

Напоминание про смену варианта. Автоконнект не отменяет правило из «Переключение варианта E ↔ W». При первом старте после переключения E → W радио AIC8801 надо поднимать холодным power cycle, тёплый reboot оставляет его залипшим (см. «Известные особенности AIC8801»). Обычные перезагрузки уже внутри W этим не страдают.

## Подключение к нескольким сетям

`wpa_supplicant` помнит все добавленные сети одновременно и автоматически выбирает доступную. Чтобы добавить вторую сеть, повторить `add_network` (вернёт `1`), задать параметры, `enable_network 1`. Supplicant сам решит к какой подключиться при следующем scan.

Список всех сетей:

```
wpa_cli -i wlan0 list_networks
```

Удалить сеть:

```
wpa_cli -i wlan0 remove_network 1
wpa_cli -i wlan0 save_config
```

## Конфиг руками (альтернатива wpa_cli)

Вместо `wpa_cli set_network` можно сразу написать сеть в файл. После правки запустить supplicant.

```
cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
country=RU

network={
    ssid="MyWPA2Net"
    key_mgmt=WPA-PSK
    psk="password_in_quotes"
}

network={
    ssid="MyWPA3Net"
    key_mgmt=SAE
    ieee80211w=2
    psk="password_in_quotes"
}
EOF
```

При повторных правках перечитать через `wpa_cli -i wlan0 reconfigure`.

## Диагностика

Если что-то не работает, в порядке вероятности:

1. `wpa_cli -i wlan0 status` — текущее состояние
2. `wpa_cli -i wlan0 list_networks` — что supplicant видит в конфиге
3. `iw dev wlan0 scan | grep -B1 -A6 ИМЯ_СЕТИ` — видит ли чип точку в эфире
4. `dmesg | grep -iE "sm_connect|assoc|auth|sae" | tail -20` — что говорит driver
5. `iw dev wlan0 link` — детали ассоциации, signal strength, bitrate

Типичные ошибки:

- `wpa_state=SCANNING` не меняется → `wpa_cli select_network N`
- `4WAY_HANDSHAKE`, потом disconnect → неверный пароль или `key_mgmt`
- `ASSOCIATING`, потом disconnect → точка отказала (PMF mismatch, MAC filter)
- `Temporary failure in name resolution` при ping — нет DNS, `cat /etc/resolv.conf`

## Известные особенности AIC8801 на LicheeRV Nano W

- Чип на плате идентифицируется как `AIC8801 U03` через SDIO vid/did `0x5449/0x0145`, но физически поддерживает 802.11ax (Wi-Fi 6) на firmware `u03`. Sipeed маркетит вариант W как AIC8800D80.
- Firmware blobs живут в `/usr/lib/firmware/aic8800_sdio/aic8800_and_aic8800D80/` (не в стандартном `/lib/firmware/aic8800D80/`). Источник это `firmware/aic8800_u03/` репозитория (полный комплект из 13 файлов, прошивка AICSemi, взята побитово из зеркала `gtxaspec/aic8800-wifi` (каталог `SDIO/driver_fw/fw/aic8800/`, sha256 совпадает)), в rootfs ставится target-ом `make aic8800-install`. Комплект обязан быть полным. Без `fmacfw_patch.bin` (76 байт) драйвер фатально падает в normal mode, а выборка «только файлы из таблицы fw_u03» недостаточна.
- Пады SDIO Wi-Fi (`SD1_D3/D2/D1/D0/CMD/CLK`, регистры `0x030010D0/D4/D8/DC/E0/E4`, func0) частично совпадают с падами I2C1/I2C3 header (I2C занимает 4 из них: SD1_D3/D0/CMD/CLK). Любой remux этих регистров на работающем радио отключает чип от шины: `buffer_cnt = -1`, `reg:9 write failed`, `cmd queue crashed`. Pinmux I2C1/I2C3 описан только в board-DTS вариантов B/E (патч 0021), на W/WE узлы i2c1/i2c3 отключены и пады остаются за sdhci1.
- Чип, прерванный посреди инициализации (оборванная заливка firmware либо тёплый reboot из другого варианта, например E → W), может зависнуть. Наблюдалось два признака. Либо чип вообще не отвечает на SDIO-енумерацию (`mmc1: Failed to initialize a non-removable card`). Либо SDIO-карта энумерируется (`mmc1: new SDIO card`) и `aic8800_bsp` грузится, но следующая фаза power-on таймаутит: `aicbsp_dummy_sdmmc ... probe ... failed with error -110`, затем `aicbsp_set_subsys, fail to set AIC_WIFI power state` и `rwnx_mod_init, set power on fail!`. В обоих случаях `aic8800_fdrv` не биндится, `wlan0` нет, `modprobe aic8800_fdrv` → `No such device` (ENODEV). Тёплый reboot не помогает (питание удерживается), лечится только холодным power cycle (снять питание на 10+ секунд).
- Powersave прошивки чипа выключен через `options aic8800_fdrv ps_on=0` в `/etc/modprobe.d/aic8800.conf` (host-side сон `CONFIG_SDIO_PWRCTRL` выключен ещё сборкой).
- На 2.4G band максимальная скорость TX около 86 Mbps (HE-MCS 7, 1 stream, 20MHz). На 5G band больше при широких каналах (но не тестировано на mainline 6.18.29).
- WPA3-SAE работает, проверено с Pixel hotspot в режиме WPA3 Personal.

## Связанные документы

- `docs/sg2002_pin_map.md` это SDIO1 pins для AIC8800
- `patches/aic8800-vendor/` это патчи vendor SDK под kernel 6.18
