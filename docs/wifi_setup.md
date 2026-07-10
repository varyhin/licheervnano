# Подключение к Wi-Fi на LicheeRV Nano W

Краткая инструкция для Wi-Fi на чипе AIC8800 + wpa_supplicant + dhclient в Debian 13 на варианте W. Существуют две ревизии платы W с разными радиомодулями (AIC8801 и AIC8800D80), образ несёт firmware для обеих, см. «Известные особенности».

Статус: работает на железе W, обе ревизии платы hw-verified 2026-07-10 на одном
образе с обоими комплектами firmware (AIC8800D80 это 49 сетей в скане, AIC8801
это 38 сетей, у обеих wlan0 поднялся, blob-fail и power-fail отсутствуют).
Powersave чипа отключён опцией ps_on=0
(см. «Известные особенности»). После reboot на W/WE Wi-Fi поднимается сам без
снятия питания, это FSBL-осушение чипа (hw-verified 2026-07-04, см. «Известные
особенности»).

Проверка одной командой на плате, печатает PASS/FAIL по каждому пункту. Скрипт
едет в образ, копировать его руками не нужно:

```
/usr/local/sbin/check-wifi.sh              # проверить радио
/usr/local/sbin/check-wifi.sh 6778e152     # плюс сверить метку прошитого образа
```

Источник это `scripts/check-wifi.sh` репозитория, в rootfs кладёт `make
aic8800-install`. Не вставлять его в консоль платы копипастом, длинные блоки
доезжают усечёнными.

## Быстрый старт (по шагам)

Линейная последовательность для варианта W. Подставь свои значения вместо `ВАШ_SSID` и `ВАШ_ПАРОЛЬ`, реальные креды в доку не пишем. Разбор каждого шага в разделах ниже.

```
cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
country=RU
EOF

chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf -D nl80211
wpa_cli -i wlan0 reconfigure

wpa_cli -i wlan0 scan            # вернёт OK
sleep 3
wpa_cli -i wlan0 scan_results    # таблица найденных сетей
```

Записать конфиг сети (пример WPA2-PSK) и подключиться:

```
cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
country=RU

network={
    ssid="ВАШ_SSID"
    key_mgmt=WPA-PSK
    psk="ВАШ_ПАРОЛЬ"
}
EOF
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf

wpa_cli -i wlan0 reconfigure

dhclient -v wlan0
```

Включить автоконнект на загрузке:

```
cat > /etc/network/interfaces.d/wlan0 <<'EOF'
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
EOF
```

Для WPA3 (SAE), скрытой или открытой сети смотри раздел «Добавление сети через wpa_cli».

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

Про первый старт W и переключение E→W. С фиксом FSBL-осушения (hw-verified 2026-07-04) `reboot` работает: FSBL обесточивает AIC8801 на загрузке, чип успевает осушиться, и в Linux `mmc-pwrseq` поднимает питание, радио встаёт само. Снимать питание вручную больше не нужно.

Историческая справка (без фикса). Раньше тёплая перезагрузка удерживала питание чипа, и радио оставалось в полузастрявшем состоянии: `aic8800_bsp` грузится, но фаза power-on таймаутит (`-110`), `aic8800_fdrv` не биндится, `wlan0` не появляется. Лечилось только снятием питания на 10+ секунд. Симптом и механизм в «Известные особенности AIC8800».

## Что должно быть до начала

- Boot варианта W из extlinux меню (пункт 4, `label nano-w`, «LicheeRV Nano-W»)
- Модули загружены автоматически через udev (по SDIO-модалиасу чипа, `5449:0145` для AIC8801 либо `C8A1:0082` для AIC8800D80):

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

Если `modprobe aic8800_fdrv` отвечает `No such device` (ENODEV), а в `lsmod` виден только `aic8800_bsp`, чип завис на фазе power-on (в `dmesg` таймаут `-110` и `set power on fail`). Ручной modprobe тут бесполезен, SDIO-функции normal mode на шине нет. Снять питание на 10+ секунд и включить заново. См. «Переключение варианта E ↔ W» и «Известные особенности AIC8800».

## Базовый конфиг wpa_supplicant

Создать один раз. Файл `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`:

```
cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
country=RU
EOF
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

## Сканирование доступных сетей

Перед добавлением сети полезно посмотреть, что чип видит в эфире. Имя SSID, тип шифрования и уровень сигнала берутся прямо из результата скана.

### Через wpa_cli (нужен запущенный supplicant)

```
wpa_cli -i wlan0 scan            # запустить скан, вернёт OK
sleep 3                          # дать чипу обойти каналы
wpa_cli -i wlan0 scan_results    # таблица найденных точек
```

Колонки `scan_results` это `bssid / frequency / signal level / flags / ssid`. Поле `flags` показывает тип защиты и определяет параметры из раздела «Добавление сети»:

- `[WPA2-PSK-CCMP][ESS]` это WPA2 Personal, нужен `key_mgmt=WPA-PSK`
- `[WPA2-PSK+SAE-...]` это transition-режим, годится `key_mgmt='WPA-PSK SAE'` и `ieee80211w=1`
- `[RSN-SAE-CCMP][MFPR][ESS]` это WPA3 Personal, нужен `key_mgmt=SAE` и `ieee80211w=2`
- `[ESS]` без `WPA`/`RSN` это открытая сеть, `key_mgmt=NONE`

Поле `signal level` в dBm. Чем ближе к нулю, тем сильнее: `-50` отличный сигнал, `-70` рабочий, ниже `-80` ассоциация ненадёжна.

Отфильтровать по имени сети:

```
wpa_cli -i wlan0 scan_results | grep -i ИМЯ_СЕТИ
```

Точки со скрытым SSID попадут в таблицу с пустым полем имени (виден только bssid). Подключение к ним описано в «Скрытая сеть».

### Через iw (без supplicant)

Работает, даже если supplicant не запущен, нужен лишь поднятый интерфейс (`ip link set wlan0 up`). Сырой вывод подробнее, но многословнее:

```
iw dev wlan0 scan | grep -iE 'SSID|signal|RSN|WPA'
```

Только список имён сетей:

```
iw dev wlan0 scan | grep SSID:
```

Карточка одной точки целиком:

```
iw dev wlan0 scan | grep -B1 -A6 ИМЯ_СЕТИ
```

Полезно, когда supplicant ещё не настроен или нужно проверить, что чип вообще принимает beacon. В `iw` тип защиты виден в блоках `RSN:` (WPA2/WPA3) и `WPA:` (старый WPA), наличие `Authentication suites: SAE` указывает на WPA3.

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

Проверено на железе W: после холодного `poweroff/poweron` `wlan0` поднимается сам и получает IP по DHCP без ручных команд (2026-06-15). После обычного `reboot` `wlan0` также встаёт сам благодаря FSBL-осушению AIC8801 (hw-verified 2026-07-04: несколько `reboot` подряд на W и переключение B→nano-w, каждый раз wlan0 поднимался).

Напоминание про смену варианта. С фиксом FSBL-осушения переключение E→W (и B→W) и любой `reboot` поднимают радио сами, холодный power cycle больше не требуется (см. «Известные особенности AIC8800»).

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

## Известные особенности AIC8800 на LicheeRV Nano W

- Две ревизии платы W несут разные радиомодули, драйвер различает их по SDIO vid/did в `aicwf_sdio_chipmatch`. Ранняя ревизия это `AIC8801 U03` (`0x5449/0x0145`, лог `USE AIC8801`), она физически поддерживает 802.11ax на firmware `u03`. Поздняя ревизия (платы закупки 2026-07) это настоящий `AIC8800D80` (`0xC8A1/0x0082`, лог `USE AIC8800D80`, `chip_rev 7`, `IS_CHIP_ID_H`). Sipeed маркетит вариант W как AIC8800D80 независимо от ревизии, поэтому определять чип надо по `dmesg`, а не по маркировке.
- Комплекты firmware выбираются в `aicbsp_driver_fw_init` (`aic_bsp_driver.c`). Для AIC8801 это список `fw_u03`, для AIC8800D80 с `IS_CHIP_ID_H` это `fw_8800d80_h_u02`. Списки не пересекаются по именам файлов, поэтому оба комплекта кладутся в один каталог, и один образ обслуживает обе ревизии.
- Чем отличаются чипы. Оба двухдиапазонные (2.4 и 5 ГГц) и оба умеют 802.11ax, у AIC8801 это видно по `ofdm1024qam_2g4`/`ofdm1024qam_5g` в `aic_userconfig.txt`, у AIC8800D80 по уровням `mcs9`/`mcs10`/`mcs11` на обоих диапазонах (MCS10 и MCS11 существуют только в HE). Различия по коду драйвера:

| Свойство | AIC8801 | AIC8800D80 |
|---|---|---|
| SDIO vid/did | `5449:0145` | `C8A1:0082` |
| Тактовая SDIO | 25 МГц (`FEATURE_SDIO_CLOCK`) | 150 МГц (`FEATURE_SDIO_CLOCK_V3`) |
| Комплект firmware | `fw_u03` | `fw_8800d80_h_u02` |
| Таблица syscfg | `aicbsp_system_config` | `aicbsp_system_config_8800d80` |
| Подревизия `chip_id_h` | нет | есть, отсюда суффикс `_h_` |
| Расширенный BT-патч | нет | `fw_patch_8800d80_u02_ext0.bin` |
| Калибровка мощности | индекс на группу модуляций | уровень на каждый MCS + канальные смещения |

  Тактовая шины это самое ощутимое отличие, выбор в `aicbsp_get_feature`. Потолок 2.4 ГГц TX около 86 Мбит/с, измеренный на AIC8801, похож на упор именно в 25 МГц SDIO, а не в радио. Версию Bluetooth по коду подтвердить нельзя, вендорские страницы называют для D80 BT 5.3, это непроверенное.
- Firmware blobs живут в `/usr/lib/firmware/aic8800_sdio/aic8800_and_aic8800D80/` (не в стандартном `/lib/firmware/aic8800D80/`). Источник это `firmware/aic8800_u03/` (13 файлов, зеркало `gtxaspec/aic8800-wifi`, каталог `SDIO/driver_fw/fw/aic8800/`) и `firmware/aic8800d80_u02/` (10 файлов, тот же репозиторий, каталог `SDIO/driver_fw/fw/aic8800D80/`). Прошивка AICSemi, взята побитово. В rootfs ставится target-ом `make aic8800-install`. Каждый комплект обязан быть полным. Для `u03` без `fmacfw_patch.bin` (76 байт) драйвер фатально падает в normal mode, выборка «только файлы из таблицы `fw_u03`» недостаточна.
- Если для распознанного чипа нет его комплекта firmware, симптом такой. SDIO энумерируется штатно (`mmc1: new high speed SDIO card`, устройства `mmc1:*:1` и `mmc1:*:2` видны), `aic8800_bsp` грузится, печатает `chipmatch`, `chip rev` и путь к первому blob-у, затем `aicbt_patch_table_alloc fail`, откат `aicbsp_sdio_remove` + `aicbsp_platform_power_off` и финальное `rwnx_mod_init, set power on fail!`. Дальше `aic8800_fdrv` не биндится, `wlan0` не создаётся, `modprobe aic8800_fdrv` отдаёт `No such device`, а `wpa_supplicant` сообщает `Could not read interface wlan0 flags: No such device`. Отличать от залипания чипа надо по наличию SDIO-устройств и по строке `aicbt_patch_table_alloc fail`, при залипании вместо неё таймаут `-110`.
- Пады SDIO Wi-Fi (`SD1_D3/D2/D1/D0/CMD/CLK`, регистры `0x030010D0/D4/D8/DC/E0/E4`, func0) частично совпадают с падами I2C1/I2C3 header (I2C занимает 4 из них: SD1_D3/D0/CMD/CLK). Любой remux этих регистров на работающем радио отключает чип от шины: `buffer_cnt = -1`, `reg:9 write failed`, `cmd queue crashed`. Pinmux I2C1/I2C3 описан только в board-DTS вариантов B/E (патч 0021), на W/WE узлы i2c1/i2c3 отключены и пады остаются за sdhci1.
- Чип, прерванный посреди инициализации (оборванная заливка firmware либо тёплый reboot из другого варианта, например E → W), может зависнуть. Наблюдалось два признака. Либо чип вообще не отвечает на SDIO-енумерацию (`mmc1: Failed to initialize a non-removable card`). Либо SDIO-карта энумерируется (`mmc1: new SDIO card`) и `aic8800_bsp` грузится, но следующая фаза power-on таймаутит: `aicbsp_dummy_sdmmc ... probe ... failed with error -110`, затем `aicbsp_set_subsys, fail to set AIC_WIFI power state` и `rwnx_mod_init, set power on fail!`. В обоих случаях `aic8800_fdrv` не биндится, `wlan0` нет, `modprobe aic8800_fdrv` → `No such device` (ENODEV). Раньше тёплый reboot не помогал (питание чипа удерживалось), лечило только снятие питания на 10+ секунд. С фиксом FSBL-осушения (`patches/fsbl/0003`) это снято: FSBL уводит питание AIC8801 (GPIOA26, active-low) в LOW рано на загрузке, чип обесточен весь остаток boot (OpenSBI + U-Boot + ядро до mmc1) и успевает осушить конденсаторы, затем `mmc-pwrseq` поднимает питание при инициализации mmc1, и радио встаёт чисто. Поэтому reboot и переключение вариантов на W/WE больше не требуют снятия питания. hw-verified 2026-07-04.
- Powersave прошивки чипа выключен через `options aic8800_fdrv ps_on=0` в `/etc/modprobe.d/aic8800.conf` (host-side сон `CONFIG_SDIO_PWRCTRL` выключен ещё сборкой).
- На 2.4G band максимальная скорость TX около 86 Mbps (HE-MCS 7, 1 stream, 20MHz). На 5G band больше при широких каналах (но не тестировано на mainline 6.18.29).
- WPA3-SAE работает, проверено с Pixel hotspot в режиме WPA3 Personal.

## Связанные документы

- `docs/sg2002_pin_map.md` это SDIO1 pins для AIC8800
- `patches/aic8800-vendor/` это патчи vendor SDK под kernel 6.18
