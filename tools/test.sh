#!/usr/bin/env bash
# Все тесты без Windows и без Porthole:
#   1) game_probe (Linux-сборка) против поддельных серверов Minecraft всех поколений
#   2) протокол агента (tests/agent_test.py)
#   3) Luau: юнит-тесты модулей и сценарии против поддельного porthole (нужен luau в PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
gcc -DTEST_MAIN -O2 -Wall -Wextra -Werror -Inative/third_party/cJSON -o build/probe_test \
    native/game_probe.c native/third_party/cJSON/cJSON.c -lpthread

echo "== probe vs fake servers"
check() { if echo "$2" | grep -q "$3"; then echo "PASS $1"; else echo "FAIL $1: $2"; exit 1; fi; }
run_fake() { (timeout "${4:-6}" python3 tests/fake_mc.py "$1" "$2" "${3:-2}" "${5:-}" >/dev/null 2>&1 &); sleep 0.7; }
run_fake lan 25701;      check "modern"       "$(timeout 8 build/probe_test --status minecraft 25701)" "ping=modern"
run_fake fancy 25702;    check "chat motd"    "$(timeout 8 build/probe_test --status minecraft 25702)" "world=Зелёный сервер"
run_fake legacy13 25703; check "legacy 1.3"   "$(timeout 8 build/probe_test --status minecraft 25703)" "ping=legacy"
run_fake legacy16 25704; check "legacy 1.6"   "$(timeout 8 build/probe_test --status minecraft 25704)" "version=1.6.4"
check "closed port" "$(build/probe_test --status minecraft 1)" "reason=connect"
LANIP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$LANIP" ]; then
  (timeout 15 python3 tests/fake_mc.py legacy13lan 25705 2 "$LANIP" >/dev/null 2>&1 &); sleep 0.7
  check "LAN-address world with throttle" "$(timeout 12 build/probe_test --try-addr "$LANIP" --status minecraft 25705)" "ping=legacy"
fi

echo "== agent protocol"
timeout 60 python3 tests/agent_test.py build/probe_test

echo "== luau"
if command -v luau >/dev/null; then
  bash tests/run_luau.sh | grep -v '^PASS'
else
  echo "luau not found, skipping"
fi
