-- game-status: плашки открытых игровых миров в лобби Porthole.
-- Главный модуль: состояние, события Porthole, протокол между участниками, связь с агентом.
local util = require("./util")
local games = require("./games")
local proto = require("./proto")
local agentmod = require("./agent")
local detect = require("./detect")
local uimod = require("./ui")

local P = porthole
local t = P.t

local HEARTBEAT_TICKS = 60 -- ~30 с: подтверждаем своё состояние
local PEER_TTL_TICKS = 180 -- ~90 с без подтверждений — запись друга протухает

local function log(s) P.log(s) end

local function setting(name, default)
	local ok, v = pcall(P.config.get, name)
	if ok and v ~= nil then return v end
	return default
end

local function opts()
	return {
		carousel = setting("carousel", "on") == "on",
		show_players = setting("show_players", "on") == "on",
		hide_names = setting("hide_names", "off") == "on",
	}
end

-- ---------- состояние ----------
local profiles = games.load(P.read_file, log)
local labels = {}
for id, p in pairs(profiles) do labels[id] = p.label end

local function new_epoch()
	local ok, tok = pcall(P.random_token, 8)
	if ok and type(tok) == "string" and string.match(tok, "^%w+$") and #tok <= 32 then return tok end
	return string.format("%x%x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

local me = nil
local now = 0                 -- тики с загрузки
local worlds = {}             -- port -> { game, title, kind, rec, reason, fails, answered }
local ignored = {}            -- port -> true: «возможно мир», не ответил три раза
local peers = {}              -- steam_id -> { epoch, seq, lan, worlds, seen }
local roster_ids = {}         -- steam_id -> true
local my_lan = nil
local epoch = new_epoch()
local out_seq = 0
local cmd_seq = 0
local last_body = nil
local last_beat = 0
local fatal_shown = false

local ui = uimod.new(P, t)
local tab = P.ui.add_tab({ panel = "sharing", title = t("tab") })

local render -- ниже
local agent

local function in_session() return P.role() ~= "" end

-- ---------- мои миры как записи протокола ----------
local function joinable(rec)
	if not my_lan then return nil end
	local a = rec.addr
	return a == nil or a == "" or a == "127.0.0.1" or a == my_lan
end

local function my_records()
	local out = {}
	for _, port in ipairs(util.sorted_keys(worlds)) do
		local w = worlds[port]
		if w.rec then
			local r = table.clone(w.rec)
			r.j = joinable(w.rec)
			out[#out + 1] = r
		end
	end
	return out
end

local function record_from_probe(port, w, f)
	local prof = profiles[w.game]
	local pl = nil
	if util.nonempty(f.players) then
		pl = {}
		for name in string.gmatch(f.players, "[^,]+") do pl[#pl + 1] = name end
	end
	local o = util.int(f.online, 0, 1000000)
	local m = util.int(f.max, 0, 1000000)
	return {
		g = w.game,
		p = port,
		ver = util.nonempty(f.version) or games.title_version(prof, w.title),
		n = util.nonempty(f.world) or util.nonempty(f.motd),
		h = util.nonempty(f.host),
		o = o,
		m = m,
		pl = pl,
		lg = f.ping == "legacy",
		addr = f.addr,
	}
end

-- ---------- сеть между участниками (gs3) ----------
local function state_body()
	-- то, что сравниваем, чтобы не слать одно и то же; seq в сравнение не входит
	return proto.encode({ epoch = epoch, seq = 0, lan = my_lan, worlds = my_records() })
end

local function state_message()
	out_seq += 1
	return proto.encode({ epoch = epoch, seq = out_seq, lan = my_lan, worlds = my_records() })
end

local function broadcast(force)
	if not in_session() then return end
	local body = state_body()
	if body == last_body and not force then return end
	-- пустое состояние шлём, только если до этого было непустое (чтобы друзья убрали плашку)
	local empty = #my_records() == 0
	if empty and (last_body == nil or last_body == body) and not force then return end
	last_body = body
	last_beat = now
	pcall(P.net.send, state_message())
end

local function send_state_to(id)
	if #my_records() == 0 then return end
	pcall(P.net.send_to, id, state_message())
end

P.net.on_message(function(from, data)
	if from == me then return end
	local d = proto.decode(data)
	if d == nil then return end
	if d == "query" then
		send_state_to(from)
		return
	end
	if next(roster_ids) ~= nil and not roster_ids[from] then return end -- не из нашего лобби
	local p = peers[from]
	if p and p.epoch == d.epoch and d.seq <= p.seq then return end -- старое или повтор
	peers[from] = { epoch = d.epoch, seq = d.seq, lan = d.lan, worlds = d.worlds, seen = now }
	render()
end)

-- ---------- агент ----------
local function push_worlds()
	if not agent.ready then return end
	cmd_seq += 1
	local args = { "worlds", tostring(cmd_seq) }
	for _, port in ipairs(util.sorted_keys(worlds)) do
		local prof = profiles[worlds[port].game]
		args[#args + 1] = (prof and prof.adapter or worlds[port].game) .. ":" .. port
	end
	agent:send(table.unpack(args))
end

local function on_probe_line(kind, f)
	local port = util.int(f.port, 1, 65535)
	local w = port and worlds[port]
	if not w then return end
	if kind == "status" then
		w.rec, w.reason, w.answered, w.fails = record_from_probe(port, w, f), nil, true, 0
	elseif kind == "offline" then
		w.fails = (w.fails or 0) + 1
		if not w.answered and w.fails < 3 then
			render() -- старые версии отвечают не с первой попытки
			return
		end
		if w.kind == "maybe" and not w.answered then
			-- три попытки без ответа: это не наша игра, отпускаем порт до его закрытия
			worlds[port] = nil
			ignored[port] = true
			push_worlds()
			render()
			return
		end
		w.rec, w.reason = nil, f.reason
	end
	broadcast()
	render()
end

local pending_copy = nil -- { key, vars }: какое уведомление показать, когда агент ответит на clip

agent = agentmod.new(P, {
	on_ready = function()
		cmd_seq = 0 -- у нового агента свой счётчик
		push_worlds()
		render()
	end,
	on_down = function()
		for _, w in pairs(worlds) do w.rec, w.reason, w.fails, w.answered = nil, nil, 0, false end
		render()
	end,
	on_fatal = function(reason)
		log("agent fatal: " .. tostring(reason))
		if not fatal_shown then
			fatal_shown = true
			P.notify("error", t("agent_failed", { reason = tostring(reason) }))
		end
	end,
	on_event = function(kind, f, line)
		if kind == "status" or kind == "offline" then
			on_probe_line(kind, f)
		elseif kind == "lanaddr" then
			local a = util.ipv4(f.addr)
			if a ~= my_lan then
				my_lan = a
				broadcast(true)
				render()
			end
		elseif kind == "clip" then
			if pending_copy then
				if f.error then
					P.notify("error", t("copy_failed", { error = f.error }))
				else
					P.notify("info", t(pending_copy.key, pending_copy.vars))
				end
				pending_copy = nil
			end
		elseif kind == "error" then
			log("agent: " .. line)
		end
	end,
})

local function on_copy(text, done_key, vars)
	if not agent:send("clip", text) then
		P.notify("error", t("copy_failed", { error = "agent" }))
		return
	end
	pending_copy = { key = done_key, vars = vars }
end

-- ---------- обнаружение ----------
P.on_listening(function(list)
	local found = detect.scan(profiles, list)
	local changed = false
	for port in pairs(ignored) do
		if not found[port] then ignored[port] = nil end
	end
	for port in pairs(worlds) do
		if not found[port] then
			worlds[port] = nil
			ui.expanded[port] = nil
			changed = true
		end
	end
	for port, info in pairs(found) do
		local w = worlds[port]
		if not w and not ignored[port] then
			worlds[port] = { game = info.game, title = info.title, kind = info.kind, fails = 0 }
			changed = true
		elseif w then
			w.title = info.title
			if info.kind == "strong" then w.kind = "strong" end
		end
	end
	if changed then
		push_worlds()
		broadcast()
		render()
	end
end)

-- ---------- отрисовка ----------
local function roster_list()
	local ok, r = pcall(P.roster)
	return (ok and type(r) == "table") and r or {}
end

render = function()
	if not in_session() then
		pcall(P.ui.render, tab, nil)
		return
	end
	local o = opts()
	local members = {}
	local names = {}
	for _, m in ipairs(roster_list()) do
		local id = m.steam_id
		names[id] = util.clean(m.name, 32)
		local list = (id == me) and my_records() or (peers[id] and peers[id].worlds) or {}
		members[#members + 1] = { id = id, worlds = list }
	end
	ui.plaques(members, labels, o)

	local mine = {}
	for _, port in ipairs(util.sorted_keys(worlds)) do
		local w = worlds[port]
		if w.kind ~= "maybe" or w.rec then
			local rec = w.rec and table.clone(w.rec) or nil
			if rec then rec.j = joinable(w.rec) end
			mine[#mine + 1] = { port = port, rec = rec, reason = w.reason }
		end
	end
	local friends = {}
	for _, id in ipairs(util.sorted_keys(peers)) do
		local p = peers[id]
		for _, w in ipairs(p.worlds) do
			friends[#friends + 1] = { who = names[id] or w.h, rec = w, lan = p.lan }
		end
	end
	ui.render(tab, {
		mine = mine,
		friends = friends,
		my_lan = my_lan,
		can_copy = agent.ready and agent:has("clip"),
		labels = labels,
		opts = o,
		on_copy = on_copy,
	}, render)
end

-- ---------- сессия ----------
local function reset_session()
	worlds, ignored, peers, roster_ids = {}, {}, {}, {}
	my_lan, last_body, pending_copy = nil, nil, nil
	ui.reset()
end

P.on_role_change(function(role)
	me = P.steam_id()
	reset_session()
	if role ~= "" then
		epoch = new_epoch() -- новая сессия — новая эпоха: друзья не спутают со старыми сообщениями
		for _, m in ipairs(roster_list()) do roster_ids[m.steam_id] = true end
		agent:start()
		pcall(P.net.send, proto.QUERY)
	else
		agent:stop()
	end
	render()
end)

P.on_roster_change(function()
	local fresh = {}
	for _, m in ipairs(roster_list()) do fresh[m.steam_id] = true end
	for id in pairs(peers) do
		if not fresh[id] then peers[id] = nil end -- ушёл из лобби
	end
	for id in pairs(fresh) do
		if not roster_ids[id] and id ~= me then send_state_to(id) end -- новичку — лично
	end
	roster_ids = fresh
	render()
end)

P.on_tick(function()
	now += 1
	agent:tick()
	local dirty = false
	for id, p in pairs(peers) do
		if now - p.seen > PEER_TTL_TICKS then
			peers[id] = nil
			dirty = true
		end
	end
	if in_session() and now - last_beat >= HEARTBEAT_TICKS and #my_records() > 0 then broadcast(true) end
	if ui.tick(opts()) then dirty = true end
	if dirty then render() end
end)

P.on_session_end(function()
	agent:stop()
	reset_session()
	render()
end)

pcall(P.on_setting_change, function()
	render()
end)

me = P.steam_id()
render()
