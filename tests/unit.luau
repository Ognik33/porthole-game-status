-- Юнит-тесты модулей (бандл в режиме --lib даёт __req)
local util = __req("util")
local toml = __req("toml")
local games = __req("games")
local proto = __req("proto")

-- util
check("clean strips control chars", util.clean("a\tb\1c", 10) == "abc")
check("clean cuts on char boundary", util.clean("Привет", 5) == "Пр")
check("clean rejects invalid utf8", util.clean("a\255b", 10) == nil)
check("ipv4 ok", util.ipv4("10.99.124.250") == "10.99.124.250")
check("ipv4 rejects 256", util.ipv4("10.99.124.256") == nil)
check("ipv4 rejects leading zero", util.ipv4("10.099.1.1") == nil)
check("ipv4 rejects junk", util.ipv4("10.99.1.1:80") == nil)
check("int range", util.int("65535", 1, 65535) == 65535 and util.int("0", 1, 65535) == nil and util.int("1.5", 1, 9) == nil)

-- toml: настоящий games.toml и ошибки
local data = toml.parse(GAMES_TOML)
check("games.toml parses", data and data.minecraft and data.minecraft.adapter == "minecraft")
check("multiline array", #data.minecraft.maybe == 9)
local bad, err = toml.parse('[x]\nkey = "unterminated\n')
check("toml error has line", bad == nil and string.find(err, "line 2", 1, true) ~= nil)

-- games
local profiles = games.load(function() return GAMES_TOML end, function() end)
check("profile loaded", profiles.minecraft.label == "Minecraft")
local logs = {}
local fallback = games.load(function() return "[bad\n" end, function(s) table.insert(logs, s) end)
check("broken games.toml -> built-in + log", fallback.minecraft ~= nil and #logs == 1)
local unknown = games.load(function() return '[valheim]\nadapter = "a2s"\nstrong = ["valheim"]\n' end, function() end)
check("unknown adapter -> built-in", unknown.minecraft ~= nil and unknown.valheim == nil)
local id, kind = games.classify(profiles, "Minecraft 26.3 - Multiplayer (LAN)")
check("classify strong", id == "minecraft" and kind == "strong")
id, kind = games.classify(profiles, "MultiMC: 1.3.2")
check("classify maybe", id == "minecraft" and kind == "maybe")
check("classify none", games.classify(profiles, "Discord.exe") == nil)
check("title version", games.title_version(profiles.minecraft, "Minecraft 1.7.10") == "1.7.10")
check("instance name", games.title_version(profiles.minecraft, "MultiMC: Create 1.20") == "Create 1.20")
check("no version from java.exe", games.title_version(profiles.minecraft, "java.exe") == nil)

-- proto: туда-обратно
local w = { g = "minecraft", p = 51807, ver = "26.3", n = "Подземный рынок", h = "Ognik33", o = 2, m = 8,
	pl = { "Ognik33", "Nez" }, j = true, lg = false }
local msg = proto.encode({ epoch = "abc", seq = 7, lan = "10.99.124.250", worlds = { w } })
local d = proto.decode(msg)
check("roundtrip header", d.epoch == "abc" and d.seq == 7 and d.lan == "10.99.124.250" and d.schema == 1)
check("roundtrip world", d.worlds[1].p == 51807 and d.worlds[1].n == "Подземный рынок" and d.worlds[1].o == 2
	and d.worlds[1].pl[2] == "Nez" and d.worlds[1].j == true and d.worlds[1].lg == false)
check("query", proto.decode("gs3?") == "query")
check("foreign message ignored", proto.decode("gs2\30game=minecraft") == nil and proto.decode("hello") == nil)

-- proto: бюджет 4096 байт
local many = {}
for i = 1, 16 do
	local pl = {}
	for k = 1, 20 do pl[k] = "Player_" .. i .. "_" .. k .. "_xxxxxxx" end
	many[i] = { g = "minecraft", p = 20000 + i, ver = string.rep("v", 32), n = string.rep("Н", 32),
		h = string.rep("h", 32), o = 20, m = 20, pl = pl, j = true }
end
local big = proto.encode({ epoch = "e", seq = 1, lan = "10.0.0.1", worlds = many })
check("budget <= 4096", #big <= 4096)
local bd = proto.decode(big)
check("budget keeps worlds, drops players first", #bd.worlds >= 8 and bd.worlds[1].pl == nil)

-- proto: валидация злых данных
local evil = "gs3\tv=1\te=x\ts=1\tlan=999.1.1.1\30g=minecraft\tp=99999\30g=../etc\tp=80\30g=minecraft\tp=25565\tn="
	.. string.rep("A", 500) .. "\to=-5\tpl=" .. string.rep("x,", 100)
local ed = proto.decode(evil)
check("evil: bad lan dropped", ed.lan == nil)
check("evil: bad port and game id dropped", #ed.worlds == 1 and ed.worlds[1].p == 25565)
check("evil: long name capped", #ed.worlds[1].n <= 64)
check("evil: negative online dropped", ed.worlds[1].o == nil)
check("evil: players capped", #ed.worlds[1].pl <= 20)
check("evil: over limit rejected", proto.decode("gs3\tv=1\te=x\ts=1" .. string.rep("x", 5000)) == nil)
check("future schema accepted, unknown keys skipped",
	proto.decode("gs3\tv=2\te=x\ts=1\tnew=1\30g=minecraft\tp=1\tzz=9").worlds[1].p == 1)
done()
