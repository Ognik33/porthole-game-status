#!/usr/bin/env bash
# Собирает dist/game-status-<версия>.paddon и dist/game_probe_cli.exe (нужны mingw-w64, python3, zip)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep '^version' addon/game-status/addon.toml | cut -d'"' -f2)
rm -rf build/game-status && mkdir -p build/game-status/native/windows-x86_64 dist
CFLAGS="-O2 -s -static-libgcc -DCJSON_HIDE_SYMBOLS -Inative/third_party/cJSON -Wl,--no-insert-timestamp"
SRC="native/game_probe.c native/third_party/cJSON/cJSON.c"
LIBS="-lws2_32 -liphlpapi"
x86_64-w64-mingw32-gcc -shared $CFLAGS -o build/game-status/native/windows-x86_64/game_probe.dll $SRC $LIBS
x86_64-w64-mingw32-gcc -DCLI_MAIN $CFLAGS -o dist/game_probe_cli.exe $SRC $LIBS
python3 tools/bundle.py build/game-status/main.luau
cp -r addon/game-status/addon.toml addon/game-status/games.toml addon/game-status/lang \
      addon/game-status/LICENSE-cJSON.txt build/game-status/
OUT="dist/game-status-$VERSION.paddon"
rm -f "$OUT"
# воспроизводимый архив: одинаковое время файлов, фиксированный порядок, без доп. атрибутов
find build/game-status -exec touch -h -d '2026-01-01 00:00:00 UTC' {} +
(cd build && find game-status | LC_ALL=C sort | zip -qX "../$OUT" -@)
echo "built $OUT"
sha256sum "$OUT" build/game-status/native/windows-x86_64/game_probe.dll dist/game_probe_cli.exe
