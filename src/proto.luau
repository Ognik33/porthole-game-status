-- proto: протокол gs3 между копиями дополнения (через porthole.net)
--
--   состояние:  "gs3" TAB v=1 TAB e=<эпоха> TAB s=<seq> [TAB lan=<ip>]  { RS <мир> }
--   мир:        g=<игра> TAB p=<порт> [TAB ver=..] [TAB n=<мир>] [TAB h=<хост>] [TAB o=<онлайн>]
--               [TAB m=<макс>] [TAB pl=<игрок,игрок>] [TAB j=1|0] [TAB lg=1]
--   запрос:     "gs3?"   (новичок просит у всех их состояние; отвечают через send_to)
--
-- Правила совместимости: v — версия схемы. Неизвестные ключи и записи пропускаются, поэтому
-- новые поля можно добавлять, не ломая старые копии. Сообщение не длиннее 4096 байт (лимит net).
local util = require("./util")

local proto = {}

proto.TAG = "gs3"
proto.QUERY = "gs3?"
proto.SCHEMA = 1
proto.LIMIT = 4096
local RS = "\30"
local MAX_WORLDS = 16

local LIMITS = { ver = 32, n = 64, h = 32 }

local function enc_value(v)
	-- значения уже очищены, но TAB/RS/переводы строк здесь недопустимы в любом случае
	return (string.gsub(tostring(v), "[\t\30\r\n]", " "))
end

local function encode_world(w, with_players, short)
	local parts = { "g=" .. w.g, "p=" .. w.p }
	local function add(k, v, max)
		if v == nil or v == "" then return end
		v = enc_value(v)
		if max then v = util.clean(v, short and math.min(max, 24) or max) or "" end
		if v ~= "" then parts[#parts + 1] = k .. "=" .. v end
	end
	add("ver", w.ver, LIMITS.ver)
	add("n", w.n, LIMITS.n)
	add("h", w.h, LIMITS.h)
	if w.o then add("o", w.o) end
	if w.m then add("m", w.m) end
	if with_players and w.pl and #w.pl > 0 then add("pl", table.concat(w.pl, ",")) end
	if w.j ~= nil then add("j", w.j and "1" or "0") end
	if w.lg then add("lg", "1") end
	return table.concat(parts, "\t")
end

-- state = { epoch, seq, lan, worlds = { {g,p,ver,n,h,o,m,pl,j,lg}, ... } }
-- Укладывается в лимит: сначала убирает списки игроков, потом укорачивает строки, потом миры.
function proto.encode(state)
	local head = { proto.TAG, "v=" .. proto.SCHEMA, "e=" .. state.epoch, "s=" .. state.seq }
	if state.lan then head[#head + 1] = "lan=" .. state.lan end
	local header = table.concat(head, "\t")
	local worlds = {}
	for i, w in ipairs(state.worlds or {}) do
		if i > MAX_WORLDS then break end
		worlds[#worlds + 1] = w
	end
	local function build(n_worlds, players, short)
		local parts = { header }
		for i = 1, n_worlds do parts[#parts + 1] = encode_world(worlds[i], players, short) end
		return table.concat(parts, RS)
	end
	local msg = build(#worlds, true, false)
	if #msg <= proto.LIMIT then return msg end
	msg = build(#worlds, false, false)
	if #msg <= proto.LIMIT then return msg end
	for n = #worlds, 0, -1 do
		msg = build(n, false, true)
		if #msg <= proto.LIMIT then return msg end
	end
	return header
end

local function decode_world(chunk)
	local _, f = util.parse_fields(chunk)
	local g = f.g
	if type(g) ~= "string" or not string.match(g, "^[a-z0-9_]+$") or #g > 16 then return nil end
	local p = util.int(f.p, 1, 65535)
	if not p then return nil end
	local w = { g = g, p = p }
	w.ver = util.clean(f.ver, LIMITS.ver)
	w.n = util.clean(f.n, LIMITS.n)
	w.h = util.clean(f.h, LIMITS.h)
	w.o = util.int(f.o, 0, 1000000)
	w.m = util.int(f.m, 0, 1000000)
	if f.pl then
		w.pl = {}
		for name in string.gmatch(f.pl, "[^,]+") do
			local c = util.clean(name, 32)
			if c and c ~= "" then w.pl[#w.pl + 1] = c end
			if #w.pl >= 20 then break end
		end
	end
	if f.j == "1" then w.j = true elseif f.j == "0" then w.j = false end
	w.lg = f.lg == "1"
	return w
end

-- -> "query" | state-таблица | nil (не наше / битое)
function proto.decode(data)
	if type(data) ~= "string" or #data > proto.LIMIT then return nil end
	if data == proto.QUERY then return "query" end
	local first = string.match(data, "^[^\30]*")
	local kind, head = util.parse_fields(first)
	if kind ~= proto.TAG then return nil end
	local v = util.int(head.v, 1, 1000)
	local seq = util.int(head.s, 0, 2147483647)
	local epoch = head.e
	if not v or not seq or type(epoch) ~= "string" or not string.match(epoch, "^%w+$") or #epoch > 32 then
		return nil
	end
	local state = { schema = v, epoch = epoch, seq = seq, lan = util.ipv4(head.lan), worlds = {} }
	local rest = string.sub(data, #first + 2)
	for chunk in string.gmatch(rest, "[^\30]+") do
		local w = decode_world(chunk)
		if w then state.worlds[#state.worlds + 1] = w end
		if #state.worlds >= MAX_WORLDS then break end
	end
	return state
end

return proto
