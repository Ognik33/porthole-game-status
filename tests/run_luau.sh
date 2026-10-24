#!/usr/bin/env bash
# Luau-тесты: юнит-тесты модулей и сценарии против поддельного porthole. Нужен luau в PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
python3 tests/gen_env.py build/env.luau
python3 tools/bundle.py --lib build/lib.luau >/dev/null
python3 tools/bundle.py build/main.luau >/dev/null
# unit: окружение + мок + библиотека
{ cat build/env.luau tests/mock_porthole.luau; echo "__req = (function()"; cat build/lib.luau; echo "end)()"; cat tests/unit.luau; } > build/t_unit.luau
luau build/t_unit.luau
for s in tests/scenario_*.luau; do
  { cat build/env.luau tests/mock_porthole.luau
    echo "__req_proto = (function()"; cat build/lib.luau; echo "end)()(\"proto\")"
    cat build/main.luau; cat "$s"; } > build/t_scn.luau
  echo "== $s"
  luau build/t_scn.luau
done
