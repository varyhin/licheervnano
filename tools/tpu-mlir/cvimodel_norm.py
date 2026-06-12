#!/usr/bin/env python3
"""Нормализованный sha256 для .cvimodel: маскирует недетерминированные поля.

Замер 2026-06-11 (det1/det2, один контейнер, одинаковые входы): расходятся
ровно (а) строка build_time "YYYY-MM-DD HH:MM:SS" в теле flatbuffer,
(б) md5 тела, 16 байт в шапке по смещению 14. Всё остальное бит-идентично.
Шапка: magic "CviModel"(8) + body_size(4) + major(1) + minor(1) + md5(16)
+ chip(16). Версию формата печатаем из major.minor.

Использование: cvimodel_norm.py file.cvimodel [...]  ->  "<sha256norm>  <ver>  <file>"
"""
import hashlib
import re
import sys

MD5_OFF = 14
MD5_LEN = 16
TS_RE = re.compile(rb"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")


def norm_sha(path):
    data = bytearray(open(path, "rb").read())
    assert data[:8] == b"CviModel", f"{path}: не cvimodel"
    ver = f"{data[12]}.{data[13]}"
    data[MD5_OFF:MD5_OFF + MD5_LEN] = b"\0" * MD5_LEN
    data, n = TS_RE.subn(b"0000-00-00 00:00:00", bytes(data))
    assert n >= 1, f"{path}: build_time не найден"
    return hashlib.sha256(data).hexdigest(), ver, n


if __name__ == "__main__":
    for p in sys.argv[1:]:
        sha, ver, n = norm_sha(p)
        print(f"{sha}  v{ver} ts={n}  {p}")
