# NPU/TPU (cvitek,tpu) bring-up

Статус: датапас ЗАКРЫТ на железе 2026-06-02 (Phase B probe + Phase C
инференс). `soph_tpu.ko` биндится к узлу `cvitek,tpu`, `/dev/cvi-tpu0`
создаётся, `mobilenet_v2` BF16 даёт `Forward OK 22.77 ms` (argmax=258
совпал с эталоном onnxruntime), `yolov5s` BF16/INT8 совпал с CMODEL.
Бенчмарки и разбор латентности 2026-06-03 в
`docs/tpu_benchmark_methodology.md`.

Аппаратный блок это NPU/TPU SG2002 (cv181x), маркетинговые 1 TOPS INT8
(практический потолок около 0.5 TOPS на ревизии 70405, плюс BF16). HAL
vendor-кода называется "mars" (= cv181x), вторая HAL "phobos" это cv180x,
нам не нужна.

Полный кабинетный анализ выполнимости остался в лабораторном журнале
проекта. Здесь практические команды и состояние bring-up.

## Что сделано (Phase B)

Ядерная сторона форвард-портнута и собирается.

- Vendor-драйвер `soph_tpu` (источник `osdrv/interdrv/v2/tpu` из
  sipeed/LicheeRV-Nano-Build) лежит pristine-снапшотом в
  `src/cvitek-tpu-vendor/{common,hal/mars,uapi}`.
- Форвард-порт 5.10 -> 6.18 в `patches/cvitek-tpu-vendor/0001-...patch`
  (ION -> dma-buf heaps, неэкспортируемый `arch_sync_dma_for_device` ->
  `dma_sync_single_*`, `class_create` 1-арг, `.remove` void,
  `MODULE_IMPORT_NS("DMA_BUF")`, `_unlocked` dma-buf варианты). Compat-шим
  мелких переименований в `src/cvitek-tpu-vendor/tpu_kernel_compat.h`.
- DT-узел `cvitek,tpu` в `patches/linux/0017-licheerv-nano-tpu.patch`
  (добавляет узел в `cv181x.dtsi`, покрывает B/E/W/WE). Клоки и ресеты
  целиком mainline.

Все правки помечены комментарием `forward-port 6.18`. TEE-путь править не
пришлось, в mars-HAL он уже no-op заглушки.

## Сборка

Модуль (ядро уже собрано в `build/linux`):

```
make -C src/cvitek-tpu-vendor \
     KDIR=$PWD/build/linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu-
```

Результат это `src/cvitek-tpu-vendor/soph_tpu.ko` (vermagic `6.18.29 SMP
mod_unload riscv`, alias `cvitek,tpu`, import_ns `DMA_BUF`).

DT-узел уже в `cv181x.dtsi` (через патч 0017), пересобирается обычной
сборкой dtbs. Проверка узла в собранном dtb:

```
dtc -I dtb -O dts build/linux/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-b.dtb \
  | grep -A12 'tpu@c100000'
```

## Проверка на железе (Phase B, ПОДТВЕРЖДЕНА 2026-06-02)

Цель этого шага это только убедиться, что драйвер биндится к узлу и
создаёт устройство. Инференс это Phase C.

1. Прошить образ со свежим dtb (узел tpu) и положить `soph_tpu.ko` в rootfs.
2. По UART после boot:

```
insmod soph_tpu.ko          # или modprobe, если установлен в /lib/modules
dmesg | grep -i tpu         # ожидаем cvi_tpu_probe end, без ошибок clk/reset
ls -l /dev/cvi-tpu0         # символьное устройство должно появиться
cat /proc/tpu/usage_profiling
```

Если probe падает на `Cannot get clk_*`/`res_*`, проверить, что dtb с
узлом действительно загружен (см. [[verify-flashed-image-identity]] в
памяти агента, сверять прошитый образ).

## Phase C (userspace runtime, ВЫПОЛНЕНО на железе 2026-06-02)

> Датапас закрыт на железе 2026-06-02: runtime собран под glibc riscv64,
> ION мигрирован на dma-buf heaps, физадрес dmabuf берётся ядерным ioctl
> `CVITPU_GET_PADDR`. Воспроизводимый рецепт в `tools/cviruntime/`. Разделы
> ниже оставлены как описание того, что было сделано, и зачем runtime нужен.

### Зачем runtime обязателен (можно ли использовать TPU без него)

Для нейросетевого инференса runtime обязателен. Без него TPU как
AI-ускоритель использовать нельзя.

У TPU на нашем железе НЕТ прошивки/микрокода на чипе (`request_firmware`
в драйвере отсутствует). Чип это исполнитель потока инструкций TIU
(тензорные операции) и TDMA (DMA). Всю работу по превращению сети в этот
поток делает userspace. Слои:

- Ядро (`soph_tpu`, готово) это труба «положи готовый cmdbuf в dmabuf →
  submit → подожди прерывание». Оно ничего не знает про сети/веса/слои и
  само не сгенерит ни одной валидной инструкции.
- Компилятор `tpu-mlir` (хост, BSD-2) это onnx/pytorch → `.cvimodel`
  (веса + граф + шаблоны инструкций под cv181x).
- Runtime на плате это берёт `.cvimodel`, на каждом инференсе СОБИРАЕТ
  конкретный cmdbuf, аллоцирует буферы, сабмитит в `/dev/cvi-tpu0`,
  читает результат.

Поэтому драйвер это необходимое, но не достаточное условие. Что делают
четыре репозитория:

- `cvikernel` это библиотека-«ассемблер» ISA TPU (кодирует опкоды
  TIU/TDMA для cv181x). Обойти нельзя, валидные инструкции для этого TPU
  больше никто не генерит.
- `cvibuilder` это формат `.cvimodel` (flatbuffers) + парсер.
- `cnpy` (MIT) это чтение/запись `.npy` (вход/выход для сэмплов).
- `cviruntime` это сам рантайм. Через `cvikernel` строит cmdbuf,
  аллоцирует device-память, сабмитит по нашему ioctl-ABI, отдаёт
  результат. Это API приложения (`CVI_NN_RegisterModel`/`CVI_NN_Forward`).

Что доступно БЕЗ runtime это только сырой TDMA-движок как DMA-копир
(ioctl `SUBMIT_PIO`, memory-to-memory в т.ч. 2D со страйдами). Полезно
для проверки датапаса (kernel self-test), но это НЕ инференс.

Главное: runtime обязателен, но НЕ закрытый блокер. Это source-available
код sophgo + открытый `tpu-mlir`. Работа здесь это «собрать и
адаптировать», не реверс с нуля. Альтернативного открытого рантайма под
cv181x TPU нет (TVM и прочее этот чип не таргетят).

### Что нужно сделать

1. Компилятор `tpu-mlir` (BSD-2, хостовый x86) скомпилировать сеть в
   `.cvimodel` под cv181x. Рецепт через контейнер podman, см. подсекцию
   «Компилятор tpu-mlir (контейнер)» ниже. ВЫПОЛНЕНО (`tools/tpu-mlir/`).
2. Runtime пересобрать из исходников под Debian glibc riscv64. Prebuilt
   `milkv-duo/tpu-sdk-sg200x` это musl+Xuantie на 5.10, под glibc
   напрямую не грузится. Репозитории `sophgo/cviruntime` +
   `sophgo/cvikernel` + `sophgo/cvibuilder` + `sophgo/cnpy`. ioctl-ABI
   runtime (`bm_npu_ioctl.h`) уже совпадает с нашим `cvi_tpu_ioctl.h`.
3. Мигрировать аллокацию буферов runtime с ION на dma-buf heaps. В
   `cviruntime/src/soc/common/cvi_device_mem.cpp` открывается `/dev/ion`
   и зовётся `ION_IOC_ALLOC`. Заменить на dma-heap (`/dev/dma_heap/...`).
   Буфер cmdbuf обязан быть физически непрерывным (CMA-heap), потому что
   ядерный драйвер требует `nents==1` и программирует абсолютный paddr.

### Компилятор tpu-mlir (контейнер, основной путь)

Воспроизводимый рецепт в `tools/tpu-mlir/` (Containerfile + `run.sh`).
Собрать образ один раз, дальше компилировать модели одной командой:

```
podman build -t tpu-mlir:local tools/tpu-mlir
tools/tpu-mlir/run.sh model_transform.py --model_name mobilenet_v2 \
    --model_def mobilenet_v2.onnx --input_shapes [[1,3,224,224]] \
    --mean 103.94,116.78,123.68 --scale 0.017,0.017,0.017 \
    --pixel_format bgr --mlir mobilenet_v2.mlir
tools/tpu-mlir/run.sh model_deploy.py --mlir mobilenet_v2.mlir \
    --chip cv181x --quantize BF16 --model mobilenet_v2_bf16.cvimodel
```

INT8 это добавить шаг калибровки (`run_calibration.py` по выборке картинок
→ `--calibration_table` в `model_deploy.py --quantize INT8`). `model_deploy`
поддерживает `--test_input`/сверку (CMODEL-симуляция на x86) это проверить
КОРРЕКТНОСТЬ cvimodel до рефлеша, без платы.

Выравнивание версий: tpu-mlir master эмитит cvimodel 1.4, что совпадает с
нашим riscv64-рантаймом (cviruntime/cvikernel/cvibuilder из master).
Переделывать рантайм НЕ нужно, формат cv18xx стабилен на 1.4.

Почему контейнер, а не pip на хосте. Wheel `tpu_mlir` это manylinux под
Python 3.10 + glibc ~2.35. Наш Debian trixie это Python 3.13 + glibc 2.41,
из-за чего прямой pip требует костылей (standalone 3.10 через uv, вырезание
бандленного glibc из wheel, yanked `opencv-python-headless==4.8.0.74`,
`setuptools<80` ради `pkg_resources`, ручные пины `protobuf==3.20.3` +
незадекларированный `psutil`). `ubuntu:22.04` в контейнере даёт ровно
ту среду, что ждёт wheel, и все эти грабли исчезают. Контейнер только
хостовый x86-компилятор, на выходе `.cvimodel` это ОС-агностичный data-файл,
он крутится на нашей Debian-плате независимо от базы образа.

Нативная сборка под trixie/python-3.13. Задача УДАЛЕНА 2026-06-12, бриф
Шаблон задачи нативной сборки tpu-mlir убран (остался в лабораторном репозитории). Для
нашего пайплайна пользы нет, артефакт идентичен контейнерному (см. ниже про
детерминизм). Вариант «upstream-контрибуция» был начат 2026-06-11 и
остановлен решением после стартовых замеров. Выжимка аудита на случай
возврата к теме. Wheel 1.28.1 соответствует тегу v1.28.1 (git 43676b3). LLVM
не submodule, а пин c67e443 отдельной docker-стадией. Ни один нативный пин не
имеет cp313-колеса, для 3.13 неизбежен numpy 2.x (NEP 50 на пути
INT8-калибровки). Промежуточная цель py3.12 сильно дешевле, по PyPI есть
cp312-колёса (numpy 1.26.4 остаётся семантики 1.x, torch 2.2.2, onnx 1.16.2,
onnxruntime 1.17.3, scipy 1.11.4, pandas 2.1.4, scikit-image 0.22.0, pybind11
2.11.1 без изменений). CMake MLIR требует pybind11 лишь >=2.9, верхний барьер
<=2.10.3 живёт только в requirements.txt. Модифицировать сам компилятор (свой
слой/codegen) можно source-build внутри контейнера py3.10, порт для этого не
нужен.

### Детерминизм cvimodel и эталонная сверка компилятора

Замер 2026-06-11, две одинаковые BF16-сборки в одном контейнере плюс артефакт
9-дневной давности. Компилятор фиксированной версии полностью детерминирован.
Во всех трёх .cvimodel расходятся ровно две вещи, строка build_time
"YYYY-MM-DD HH:MM:SS" в теле flatbuffer и md5 тела, 16 байт в шапке по
смещению 14. Шапка устроена как magic "CviModel"(8) + body_size(4) + major(1)
+ minor(1) + md5(16) + chip(16), версия формата читается из байтов 12-13.
Таблица калибровки (kl, coco128 x100) детерминирована численно, между
прогонами меняется только комментарий "# genetated time". Флаги
`--test_input`/`--test_reference` в model_deploy на эмиссию не влияют.

Инструменты:
- `tools/tpu-mlir/cvimodel_norm.py` печатает нормализованный sha256
  (маскирует md5 шапки и build_time) и версию формата
- `tools/tpu-mlir/gen_etalon.sh` генерирует референс-набор (mobilenet_v2
  BF16/INT8, yolov5s BF16/INT8/io8, таблицы калибровки) и `MANIFEST.norm.txt`
- `tools/tpu-mlir/etalon_v1.28.1_manifest.txt` это зафиксированный эталон
  текущего компилятора (wheel 1.28.1)

После любого обновления контейнера или wheel прогнать gen_etalon.sh и
сравнить манифесты. Совпадение значит компилятор эмитит бит-в-бит то же
самое и перевалидация моделей на железе не нужна. Расхождение значит
поведение компилятора изменилось, дальше численная проверка (CMODEL npz,
argmax на плате). npz хешами не сверять (внутри zip с mtime), только
численно. Полный рабочий каталог замера с исходниками референс-набора лежит
локально в /root/tpu_mlir_native/etalon, в репо он не входит.

### Kernel-config (ВЫПОЛНЕНО 2026-06-02)

Ядро пересобрано с dma-buf heaps + CMA. cmdbuf обязан быть физически
непрерывным (драйвер требует `nents==1`), поэтому runtime аллоцирует из
CMA dma-heap. Флаги добавлены в Makefile-таргет `kernel:` (scripts/config),
не ad-hoc в `build/linux/.config`:

```
--enable CMA --enable DMA_CMA \
--enable CMA_SIZE_SEL_MBYTES --set-val CMA_SIZE_MBYTES 64 \
--enable DMABUF_HEAPS --enable DMABUF_HEAPS_SYSTEM --enable DMABUF_HEAPS_CMA
```

Применяется полным `make kernel` (он `rm -rf build/linux` + defconfig +
scripts/config + Image+dtbs+modules + modules_install). Результат:
`cma_heap` встроен в vmlinux (`add_default_cma_heap`), на boot ожидается
`/dev/dma_heap/` с CMA-областью (`CONFIG_DMABUF_HEAPS_CMA_LEGACY=y` даёт
legacy-имя heap'а под совместимость с runtime). `CONFIG_DMA_SHARED_BUFFER=y`
уже было (нужно для самого драйвера).

КРИТИЧНО (стоило рефлеша): `CONFIG_DMA_CMA` добавляет поле `cma_area` в
`struct device`, сдвигая `of_node`/`fwnode`. `CONFIG_MODVERSIONS` выключен,
поэтому модули, собранные БЕЗ этого флага, грузятся и падают Oops в
OF/fwnode core. Значит конфиг-флаг нельзя «доустроить» только в Image это
ОБЯЗАТЕЛЬНО полный `make kernel` (ядро + ВСЕ модули) + `make aic8800-install`
+ пересборка `soph_tpu`. См. память `kernel-config-change-needs-module-rebuild`.

CMA-резерв 64МБ это компромисс на 256МБ RAM. Область reusable (под movable
страницы, когда не занята DMA), так что не «теряется» целиком. Тюнится без
пересборки через kernel cmdline `cma=NN` (правится в extlinux-меню).

Сэмпл для финальной проверки это `mobilenet_v2.cvimodel` через
`cvi_sample_classifier` (см. `milkv-duo/tpu-sdk-sg200x` samples).

## Финализация (после железа)

Когда bring-up подтвердится на плате, оформить как остальные компоненты:

- Закоммитить pristine-снапшот `src/cvitek-tpu-vendor/` + патчи.
- Дописать `src/cvitek-tpu-vendor` в `Makefile` (patches-apply/build).
- Установить `soph_tpu.ko` в rootfs `modules_install`-шагом.
- Зафиксировать в `manifest/sources.mk` SHA vendor-источника, если нужно.

## Принцип тонкого форка рантайма

cviruntime/cvikernel/cvibuilder/cnpy это НЕ наш код, а upstream sophgo,
клонируемый по фиксированным SHA (`tools/cviruntime/build.sh` REPO_SHA +
`manifest/sources.mk`). Нам пришлось его изменить (ION→dma-heap + ioctl
GET_PADDR). Наша дельта поверх upstream это «форк», и мы держим его ТОНКИМ.

Что это значит на нашем примере:
- Вся наша правка живёт в ОДНОМ файле `tools/cviruntime/0001-dma-heap-getpaddr.patch`
  (240 строк), сконцентрирована в аллокаторе буферов. Клон остаётся ЧИСТЫМ
  снапшотом upstream. `build.sh` берёт pristine по SHA и накладывает патч.
  Мы НЕ храним «нашу модифицированную версию cviruntime», только «оригинал +
  один маленький патч».
- Тонким держат по двум осям: по объёму (менять как можно меньше строк и
  функций, только строго необходимое) и по форме (вся дельта в патче, а не
  вписана в исходники; исходники остаются нетронутым снапшотом).

Зачем (это правило сопровождения, не разовое действие):
- Дешёвое обновление пинов. Тонкий изолированный патч либо ложится на свежий
  upstream чисто, либо требует минимальной правки. Толстый форк (наредактировано
  прямо в исходниках в N местах) делает каждое обновление merge-адом, и на
  практике кончается тем, что не обновляются никогда и застревают на старой
  версии с её багами.
- Возможность отдать в upstream. Чистую отдельную дельту (напр. dma-heap
  миграцию) можно предложить проекту; размазанный форк нельзя.
- Понятность и меньше своих багов. Вся разница с upstream в одном файле; чем
  ближе к оригиналу, тем больше пользы от их тестирования и фиксов.

Как НЕ испортить (форк уже тонкий, задача его сохранить): при будущих правках
НЕ вписывать в исходники напрямую и НЕ раздувать патч; всё новое проводить тем
же изолированным минимальным способом. Это тот же принцип, что для патчей ядра
(`patches/` поверх чистого `src/`, см. README), применённый к рантайму TPU.
GET_PADDR это наш ad-hoc для отсутствия IOMMU, upstream его не примет; dma-heap
миграция теоретически upstream-пригодна. При обновлении пинов (`build.sh`
REPO_SHA) гейт это плата: cvimodel должен остаться 1.4 (контракт с tpu-mlir),
argmax mobilenet/yolo == эталон. См. реестр улучшений (роадмап, раздел TPU).

Проверка 2026-06-11: ОБНОВЛЯТЬ НЕЧЕГО, мы уже на upstream HEAD. Все четыре репо
заморожены ровно на наших пинах (HEAD == пин, 0 коммитов сверху): cviruntime
ef80449 (2024-10-10), cvikernel 0b37e46 (2024-10-10), cvibuilder 4309f2a
(2024-05-13), cnpy 4e8810b (2018-05-31). Upstream cviruntime/cvikernel неактивен
с октября 2024. Наш патч 0001 применяется на свежий HEAD чисто (`git apply
--check` exit 0), cvimodel MajorVersion не менялся это форк подтверждённо тонкий.
Задача «обновить пины» это no-op до возобновления upstream; возвращаться при
появлении новых коммитов в sophgo/cviruntime.

## Оптимизация и hardening (будущее, НЕ сейчас)

Порядок строгий: сначала рабочий baseline на железе + замер, потом
точечная оптимизация измеренного узкого места. Оптимизировать
непроверенный стек это backwards. Оптимизация кода рантайма стабильность
не улучшает, а ухудшает; держим форк vendor-кода тонким (см. раздел выше),
чтобы подтягивать upstream.

Hardening сделано: (1) аудит когерентности кеша
(аудит когерентности в лабораторном репозитории, модель полная+корректная, подтверждена
кодом и multi-model soak). (2) `-Werror` 2026-06-12: НАШИ раннеры (tpu_smoke/
bench/yolo/soak + cast_bench) собираются с `-Wall -Wextra -Werror` (build.sh),
все проходят чисто это будущие warning'и в нашем коде ловятся. Vendor cviruntime
CMake остаётся БЕЗ `-Werror` НАМЕРЕННО (патч 0001 снял его: mainline-заголовки
дают warnings в vendor-коде, чинить чужой код = против тонкого форка).

Где оптимизация кода рантайма НЕ помогает:
- Сам счёт (conv/matmul) делает TPU-железо, скорость задана кремнием +
  скомпилированным `.cvimodel`. C++ в cviruntime/cvikernel это не ускорит.
- cvikernel это кодировщик инструкций, последовательность задаёт tpu-mlir.
- cvibuilder это парсинг один раз, cnpy это только тесты.

Реальные рычаги в коде рантайма (только при подтверждении профайлером):
- CPU-fallback операции (`cpu_function/*`) на медленном C906. Мы собрали
  стандартным `rv64gc`, выкинув vendor Xuantie-флаги (`rv64gcv0p7_zfh_xthead`),
  поэтому CPU-fallback у нас СКАЛЯРНЫЙ, vendor использовал RVV 0.7 (вектор).
  Для классификации мизер, для детекции с тяжёлой постобработкой заметно.
  Фикс это либо Xuantie-тулчейн (нестандартный), либо ручная RVV-векторизация.
- Сузить scope cache-flush (`dma_sync`) если sync доминирует на крупных буферах.
- Переиспользование буферов если per-inference alloc доминирует.

Главный перф-рычаг вообще не в рантайме, а в `tpu-mlir` (квантизация
INT8 vs BF16, фьюзинг слоёв, архитектура модели). Отдельная задача.

Hardening (не оптимизация, а корректность/надёжность):
- Вернуть `-Werror` выборочно или просмотреть warnings (gcc-14 поймал
  реальный `format-overflow`, мы заглушили скопом удалением `-Werror`).
- pagemap имеет краевые случаи (huge pages, не-present страницы).
  Надёжнее долгосрочно это ioctl в `soph_tpu` «dmabuf-fd → физадрес»
  (драйвер это уже умеет внутри `prepare_buffer`), вместо `/proc/self/pagemap`.
- Проверить корректность когерентности кеша (направление `dma_sync`) на железе.
