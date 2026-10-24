-- Сценарий: хост с мирами, друг, агент, настройки
local ME, FRIEND, NEW = "111", "222", "333"
H.roster = { { steam_id = ME, name = "Ognik33" }, { steam_id = FRIEND, name = "Nezeramos" } }
set_role("host", ME)
H.role_cb("host")
check("agent started with port and token", agent_h().spec.args[1] == "--agent" and #agent_h().spec.args[3] >= 16)
check("query sent on join", H.sent[#H.sent] == "gs3?")
agent_say("hello\tproto=1\tversion=0.3.0\tcaps=clip,lan")
agent_say("ready\tport=41000")
check("empty worlds pushed on ready", string.find(last_tcp(), "\tworlds\t1", 1, true) ~= nil)

local A = { proto = "tcp", program = "Minecraft 26.3 - Multiplayer (LAN)", port = 51807 }
local B = { proto = "tcp", program = "Minecraft 1.7.10", port = 62155 }
H.listening({ A, B, { proto = "tcp", program = "Discord.exe", port = 6463 } })
check("desired worlds pushed", string.find(last_tcp(), "\tworlds\t2\tminecraft:51807\tminecraft:62155", 1, true) ~= nil)
check("tcp command carries token", string.match(last_tcp(), "^([^\t]+)") == agent_h().spec.args[3])

agent_say("lanaddr\taddr=10.99.124.250")
agent_say("status\tgame=minecraft\tport=51807\tversion=26.3\tprotocol=800\tonline=1\tmax=8\tmotd=Ognik33 - Survival\thost=Ognik33\tworld=Survival\tplayers=Ognik33\tping=modern\taddr=127.0.0.1")
check("plaque shows world", H.fields[ME].game_minecraft == "26.3 · Survival · 1/8")
agent_say("status\tgame=minecraft\tport=62155\tversion=1.7.10\tprotocol=5\tonline=1\tmax=8\tmotd=Ognik33 - New World\thost=Ognik33\tworld=New World\tplayers=Ognik33\tping=modern\taddr=127.0.0.1")
check("carousel frame 1", H.fields[ME].game_minecraft == "1/2 ▸ 26.3 · Survival · 1/8")
local calls = H.field_calls
ticks(4)
check("no plaque update before frame change", H.field_calls == calls)
ticks(4)
check("carousel frame 2", H.fields[ME].game_minecraft == "2/2 ▸ 1.7.10 · New World · 1/8")

local last = H.sent[#H.sent]
local d = __req_proto.decode(last)
check("state broadcast with lan and 2 worlds", type(d) == "table" and d.lan == "10.99.124.250" and #d.worlds == 2 and d.worlds[1].j == true)

-- карусель выключена
H.config.carousel = "off"
H.setting_cb()
check("carousel off -> first + (+N)", H.fields[ME].game_minecraft == "26.3 · Survival · 1/8  (+1)")
H.config.carousel = nil

-- скрытие имён
find_button("w_51807").on_press()
check("expanded shows host", string.find(tree_text(), "Ognik33", 1, true) ~= nil)
H.config.hide_names = "on"
H.setting_cb()
check("hide_names hides host/players", string.find(tree_text(), "Ognik33", 1, true) == nil)
H.config.hide_names = nil
H.setting_cb()

-- копирование
find_button("copyaddr_51807").on_press()
check("clip command sent", string.find(last_tcp(), "\tclip\t10.99.124.250:51807", 1, true) ~= nil)
agent_say("clip\tok")
check("copy notification", H.notes[#H.notes] == "info: Адрес 10.99.124.250:51807 скопирован")

-- друг
local fmsg = __req_proto.encode({ epoch = "f1", seq = 3, lan = "10.99.124.100",
	worlds = { { g = "minecraft", p = 55555, ver = "20w14~", n = "Nezolution", h = "Nez", o = 1, m = 8, j = true } } })
H.msg_cb(FRIEND, fmsg)
check("friend plaque", H.fields[FRIEND].game_minecraft == "20w14~ · Nezolution · 1/8")
check("friend in tab with Steam name", string.find(tree_text(), "Nezeramos: Minecraft 20w14~", 1, true) ~= nil)
check("friend copy button", find_button("peeraddr_1_55555") ~= nil)
H.msg_cb(FRIEND, __req_proto.encode({ epoch = "f1", seq = 2, worlds = {} }))
check("older seq ignored", H.fields[FRIEND].game_minecraft ~= nil)
H.msg_cb(FRIEND, __req_proto.encode({ epoch = "f2", seq = 1, worlds = {} }))
check("new epoch accepted (restart)", H.fields[FRIEND].game_minecraft == nil)
H.msg_cb(FRIEND, fmsg:gsub("e=f1", "e=f3"))
check("friend back", H.fields[FRIEND].game_minecraft ~= nil)

-- запрос новичка и новичок в ростере
local before = #H.sent_to
H.msg_cb(NEW, "gs3?")
check("query answered via send_to", #H.sent_to == before + 1 and H.sent_to[#H.sent_to].to == NEW)
table.insert(H.roster, { steam_id = NEW, name = "Newbie" })
H.roster_cb()
check("newcomer gets state personally", H.sent_to[#H.sent_to].to == NEW)

-- друг ушёл
H.roster = { { steam_id = ME, name = "Ognik33" }, { steam_id = NEW, name = "Newbie" } }
H.roster_cb()
check("departed friend pruned from tab", string.find(tree_text(), "Nezeramos", 1, true) == nil)

-- протухание
H.roster = { { steam_id = ME }, { steam_id = FRIEND, name = "Nezeramos" } }
H.roster_cb()
H.msg_cb(FRIEND, fmsg:gsub("e=f1", "e=f4"))
check("friend present", H.fields[FRIEND].game_minecraft ~= nil)
local sent_before = #H.sent
ticks(181)
check("friend expired after TTL", H.fields[FRIEND].game_minecraft == nil)
check("heartbeat sent while silent", #H.sent > sent_before)

-- мир закрылся (один из двух), потом второй
H.listening({ A })
check("closed world removed from desired set", string.find(last_tcp(), "\tworlds\t%d+\tminecraft:51807$") ~= nil
	or string.find(last_tcp(), "minecraft:62155", 1, true) == nil)
check("plaque single world again", H.fields[ME].game_minecraft == "26.3 · Survival · 1/8")
H.listening({})
check("last world closed -> own plaque removed", H.fields[ME].game_minecraft == nil)
check("tab says no worlds", string.find(tree_text(), "Открытых миров нет", 1, true) ~= nil)
check("no UI errors logged", (function()
	for _, l in ipairs(H.logs) do if string.find(l, "set_member_field", 1, true) then return false end end
	return true
end)())
H.listening({ A })
agent_say("status\tgame=minecraft\tport=51807\tversion=26.3\tprotocol=800\tonline=1\tmax=8\tmotd=Ognik33 - Survival\thost=Ognik33\tworld=Survival\tplayers=Ognik33\tping=modern\taddr=127.0.0.1")
check("world reopened -> plaque back", H.fields[ME].game_minecraft == "26.3 · Survival · 1/8")

-- падение агента и перезапуск
local n_helpers = #H.helpers
agent_h().spec.on_exit(nil, nil)
check("statuses reset while agent down", string.find(tree_text(), "опрашиваю", 1, true) ~= nil)
ticks(10)
check("agent restarted after ~5 s", #H.helpers == n_helpers + 1)
agent_say("hello\tproto=1\tversion=0.3.0\tcaps=clip,lan")
agent_say("ready\tport=41002")
check("desired state re-sent to new agent", string.find(last_tcp(), "\tworlds\t1\tminecraft:51807", 1, true) ~= nil)

-- конец сессии
set_role("", ME)
H.end_cb()
check("agent stopped on session end", agent_h().stopped)
done()
