#!/bin/bash
# Перекачка src/<comp> из официального upstream на пине манифеста.
# Вызывается через make refetch COMP=<имя> SOURCE=upstream, аргументы
# подставляет Makefile из manifest/sources.mk:
#   refetch.sh <comp> <url> <pin> <exclude> [subpath...]
#
# После перекачки проверка это git status по src/<comp>. Пустой вывод
# означает, что снапшот в репозитории идентичен дереву upstream на пине
# (нет дрейфа). Непустой вывод это либо намеренное обновление пина, либо
# повод разбираться.
set -euo pipefail

comp=$1; url=$2; pin=$3; exclude=$4; shift 4
proj=$(cd "$(dirname "$0")/.." && pwd)
dst=$proj/src/$comp
tmp=$(mktemp -d "${TMPDIR:-/tmp}/refetch-$comp-XXXXXX")
trap 'rm -rf "$tmp"' EXIT

git init -q "$tmp"
git -C "$tmp" remote add origin "$url"
if [ $# -gt 0 ]; then
    git -C "$tmp" sparse-checkout set "$@"
fi
# Сначала пробуем забрать ровно один коммит по SHA (github это умеет),
# при отказе хоста качаем всю историю blob:none.
if ! git -C "$tmp" fetch -q --filter=blob:none --no-tags origin "$pin"; then
    echo "fetch по SHA не поддержан хостом, качаю историю целиком"
    git -C "$tmp" fetch -q --filter=blob:none --no-tags origin
fi
git -C "$tmp" checkout -q "$pin"

if [ $# -eq 1 ] && [ -d "$tmp/$1" ]; then
    # одиночный подпуть-каталог: его содержимое становится src/<comp>
    rsync -a --delete --exclude=.git "$tmp/$1/" "$dst/"
elif [ $# -gt 0 ]; then
    # набор подпутей: каждый ложится в корень src/<comp>
    rm -rf "$dst"
    mkdir -p "$dst"
    for p in "$@"; do
        cp -a "$tmp/$p" "$dst/"
    done
else
    # компонент целиком
    rsync -a --delete --exclude=.git "$tmp/" "$dst/"
fi

# Намеренные исключения снапшота (EXCLUDE_<comp> в манифесте)
if [ -n "$exclude" ]; then
    for e in $exclude; do
        rm -f "$dst/$e"
    done
fi

echo "src/$comp перекачан из $url @ $pin"
echo "проверка дрейфа: git status --short -- src/$comp (пусто = идентичен upstream)"
