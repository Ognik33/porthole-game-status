#!/usr/bin/env python3
"""Готовит окружение для Luau-тестов: строки перевода и games.toml как Luau-значения."""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
addon = root / "addon" / "game-status"
out = pathlib.Path(sys.argv[1])

def long_str(s):
    eq = "="
    while f"]{eq}]" in s:
        eq += "="
    return f"[{eq}[\n{s}]{eq}]"

lines = ["STRINGS = {"]
for line in (addon / "lang" / "russian.toml").read_text(encoding="utf-8").splitlines():
    m = re.match(r'^([a-z_]+) = "(.*)"$', line)
    if m:
        value = m.group(2).replace(chr(92) + chr(34), chr(34)).replace(chr(92) * 2, chr(92))
        lines.append(f"\t{m.group(1)} = {long_str(value)},")
lines.append("}")
lines.append("GAMES_TOML = " + long_str((addon / "games.toml").read_text(encoding="utf-8")))
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
