-- Поддельный porthole для тестов. Записывает всё, что дополнение делает, в H.*
H = {
	listening = nil, role_cb = nil, roster_cb = nil, end_cb = nil, tick_cb = nil, msg_cb = nil, setting_cb = nil,
	sent = {}, sent_to = {}, tcp = {}, fields = {}, field_calls = 0, notes = {}, helpers = {}, renders = 0,
	tree = nil, config = {}, roster = {}, logs = {},
}
local role, sid = "", nil
function set_role(r, id) role, sid = r, id end

local function fmt(s, vars)
	return (string.gsub(s, "{(%w+)}", function(k) return tostring((vars or {})[k] or "{" .. k .. "}") end))
end

porthole = {
	t = function(key, vars)
		local s = STRINGS[key]
		assert(s, "missing translation key: " .. tostring(key))
		return fmt(s, vars)
	end,
	lang = function() return "russian" end,
	log = function(s) table.insert(H.logs, s) end,
	notify = function(level, s) table.insert(H.notes, level .. ": " .. s) end,
	role = function() return role end,
	steam_id = function() return sid end,
	roster = function() return role == "" and {} or H.roster end,
	read_file = function(name)
		if name == "games.toml" then return GAMES_TOML end
		error("no such file " .. name)
	end,
	free_port = function() return 41000 + #H.helpers end,
	random_token = function(n) return string.rep("a", (n or 16)) .. tostring(#H.helpers) end,
	config = { get = function(k) return H.config[k] end },
	on_setting_change = function(f) H.setting_cb = f end,
	on_listening = function(f) H.listening = f end,
	on_role_change = function(f) H.role_cb = f end,
	on_roster_change = function(f) H.roster_cb = f end,
	on_session_end = function(f) H.end_cb = f end,
	on_tick = function(f) H.tick_cb = f end,
	tcp_send = function(port, text)
		assert(type(text) == "string" and utf8.len(text), "tcp_send: text must be UTF-8")
		table.insert(H.tcp, { port = port, text = text })
	end,
	net = {
		send = function(s)
			assert(#s <= 4096, "net.send over 4096 bytes: " .. #s)
			table.insert(H.sent, s)
		end,
		send_to = function(to, s)
			assert(#s <= 4096, "net.send_to over 4096 bytes")
			table.insert(H.sent_to, { to = to, data = s })
		end,
		on_message = function(f) H.msg_cb = f end,
	},
	run_helper = function(spec)
		local h = { spec = spec, stopped = false }
		function h.stop(self) self.stopped = true end
		table.insert(H.helpers, h)
		return h
	end,
	ui = {
		add_tab = function() return "tab" end,
		render = function(tab, tree) H.renders += 1; H.tree = tree end,
		set_member_field = function(s)
			-- как настоящий Porthole: подпись обязательна, в том числе при снятии плашки
			assert(type(s.member) == "string" and type(s.key) == "string", "member and key required")
			assert(type(s.label) == "string", "label must be a string")
			H.field_calls += 1
			H.fields[s.member] = H.fields[s.member] or {}
			H.fields[s.member][s.key] = s.value
		end,
	},
}

-- помощники для сценариев
function agent_h() return H.helpers[#H.helpers] end
function agent_say(line) agent_h().spec.on_output(line) end
function ticks(n) for _ = 1, n do H.tick_cb() end end
function last_tcp() return H.tcp[#H.tcp] and H.tcp[#H.tcp].text or nil end
function tree_text()
	local out = {}
	local function walk(n)
		if type(n) ~= "table" then return end
		for _, v in ipairs(n) do
			if type(v) == "string" then out[#out + 1] = v end
			if type(v) == "table" then walk(v) end
		end
		if n.label then out[#out + 1] = n.label end
	end
	walk(H.tree or {})
	return table.concat(out, " | ")
end
function find_button(id)
	local found
	local function walk(n)
		if type(n) ~= "table" or found then return end
		if n.id == id then found = n return end
		for _, v in ipairs(n) do walk(v) end
	end
	walk(H.tree or {})
	return found
end
local passed = 0
function check(name, cond)
	if not cond then error("FAIL " .. name, 2) end
	passed += 1
	print("PASS " .. name)
end
function done() print("OK " .. passed .. " checks") end
