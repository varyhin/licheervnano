#!/usr/bin/env python3
# Безопасная смена клока TPU cv181x через /dev/mem (без busybox-зависимости).
# Делает ровно то, что clk-framework: read-modify-write поля мукса [9:8] и
# делителя [19:16] в REG_DIV_CLK_TPU, плюс бит EN_DIV_FACTOR (3). Отдельного
# assert-импульса у этого делителя нет (см. div_helper_set_rate в ядре).
#
# Сохраняет оригинал в /tmp/tpu_clk_orig для чистого отката. Перезагрузка
# тоже всё возвращает (FSBL перешивает регистр). Напряжение НЕ трогается.
#
#   python3 set_tpu_clk.py read     показать текущее
#   python3 set_tpu_clk.py 900      mipimpll/1 = 900 МГц (разгон, обратимо)
#   python3 set_tpu_clk.py 700      tpll/2 = 700 МГц (штатно)
#   python3 set_tpu_clk.py revert   восстановить сохранённый оригинал
import sys, os, mmap, struct

CLK_BASE = 0x03002000          # страница clkgen (выровнена)
REG_OFF  = 0x54                # REG_DIV_CLK_TPU = 0x03002054
ORIG     = "/tmp/tpu_clk_orig"
PAGE     = 0x1000

# источники мукса clk_tpu (поле [9:8], 2 бита) и их частоты (МГц) из clk_summary
# mux=0 (index0) на этом железе эмпирически это tpll (clk_summary: TPU=700=tpll/2)
PARENT = {0: ("tpll(idx0)", 1400), 1: ("tpll", 1400), 2: ("a0pll", 442), 3: ("mipimpll", 900)}
# целевые режимы: имя -> (mux, div)
PRESET = {"900": (3, 1), "700": (1, 2), "750": (None, None)}  # 750=fpll нужен bypass, не тут

def rd():
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=CLK_BASE)
    v = struct.unpack("<I", m[REG_OFF:REG_OFF + 4])[0]
    return fd, m, v

def wr(m, v):
    m[REG_OFF:REG_OFF + 4] = struct.pack("<I", v)

def decode(v):
    mux = (v >> 8) & 0x3
    div = (v >> 16) & 0xF
    en  = (v >> 3) & 0x1
    pn, pr = PARENT.get(mux, ("?", None))
    rate = (pr / div) if (en and pr and div) else None
    rs = f"{rate:.0f} МГц" if rate else "?"
    return f"reg=0x{v:08x} mux={mux}({pn}) div={div} en_factor={en} -> TPU {rs}"

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 1
    cmd = sys.argv[1]
    fd, m, old = rd()
    print("текущее:", decode(old))

    if cmd == "read":
        m.close(); os.close(fd); return 0

    if cmd == "revert":
        if not os.path.exists(ORIG):
            print("нет сохранённого оригинала; перезагрузка вернёт штатно"); m.close(); os.close(fd); return 1
        orig = int(open(ORIG).read().strip(), 16)
        wr(m, orig)
        print("восстановлено:", decode(rd()[2]))
        m.close(); os.close(fd); return 0

    if cmd not in PRESET or PRESET[cmd][0] is None:
        print(f"режим '{cmd}' не поддержан (есть: 900, 700, read, revert)"); m.close(); os.close(fd); return 1

    mux, div = PRESET[cmd]
    new = old
    new = (new & ~(0x3 << 8)) | (mux << 8)
    new = (new & ~(0xF << 16)) | (div << 16)
    new |= (1 << 3)  # EN_DIV_FACTOR
    if not os.path.exists(ORIG):
        open(ORIG, "w").write(f"0x{old:08x}\n")
        print(f"оригинал сохранён в {ORIG}: 0x{old:08x}")
    wr(m, new)
    print("установлено:", decode(rd()[2]))
    print("ВАЖНО: clk_summary покажет старое (framework не знает), верь замеру forward")
    m.close(); os.close(fd); return 0

sys.exit(main())
