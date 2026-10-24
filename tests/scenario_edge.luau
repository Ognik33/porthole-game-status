-- Сценарий: лаунчеры, старые версии, несовместимый агент
local ME = "111"
H.roster = { { steam_id = ME } }
set_role("host", ME)
H.role_cb("host")
agent_say("hello\tproto=1\tversion=0.3.0\tcaps=clip,lan")
agent_say("ready\tport=41000")
local MMC = { proto = "tcp", program = "MultiMC: 1.3.2", port = 50168 }
local IDE = { proto = "tcp", program = "java.exe", port = 8080 }
H.listening({ MMC, IDE })
check("maybe worlds probed", string.find(last_tcp(), "minecraft:8080", 1, true) and string.find(last_tcp(), "minecraft:50168", 1, true))
check("maybe worlds hidden until answered", string.find(tree_text(), "8080", 1, true) == nil)
agent_say("offline\tgame=minecraft\tport=50168\treason=timeout")
agent_say("offline\tgame=minecraft\tport=8080\treason=timeout")
agent_say("status\tgame=minecraft\tport=50168\tversion=\tprotocol=-1\tonline=1\tmax=8\tmotd=Ognik33 - Old\thost=Ognik33\tworld=Old\tplayers=\tping=legacy\taddr=192.168.0.245")
check("old world shown with instance name", H.fields[ME].game_minecraft == "1.3.2 · Old · 1/8")
agent_say("offline\tgame=minecraft\tport=8080\treason=timeout")
agent_say("offline\tgame=minecraft\tport=8080\treason=protocol")
check("java.exe dropped after 3 tries", string.find(last_tcp(), "minecraft:8080", 1, true) == nil)
H.listening({ MMC, IDE })
check("dropped port stays ignored", string.find(last_tcp(), "minecraft:8080", 1, true) == nil)
agent_say("lanaddr\taddr=10.99.124.250")
-- единственный мир раскрыт по умолчанию
check("legacy chip", string.find(tree_text(), "старый протокол", 1, true) ~= nil)
check("home-only chip for LAN-address world", string.find(tree_text(), "только домашняя сеть", 1, true) ~= nil)
local d = __req_proto.decode(H.sent[#H.sent])
check("j=0 sent for home-only world", d.worlds[1].j == false)

-- агент другой версии протокола
agent_h().spec.on_exit(nil, nil)
ticks(10)
agent_say("hello\tproto=2\tversion=9.9.9")
check("incompatible agent -> one error", #H.notes == 1 and string.find(H.notes[1], "error:", 1, true) == 1)
local n = #H.helpers
ticks(200)
check("no restart loop after fatal", #H.helpers == n)
done()
