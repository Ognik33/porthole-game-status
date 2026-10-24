-- agent: жизненный цикл game_probe --agent и общение с ним
--   события  — строки stdout через run_helper.on_output (работают и вне лобби)
--   команды  — porthole.tcp_send на 127.0.0.1:<порт агента>, каждая строка начинается с токена
local util = require("./util")

local agent = {}
agent.__index = agent

local PROTO = 1
local BACKOFF = { 10, 20, 40, 120 } -- тики (~0,5 с): 5 с, 10 с, 20 с, 60 с
local STABLE_TICKS = 120            -- после минуты нормальной работы счётчик неудач сбрасывается

local function make_token(P)
	local ok, t = pcall(P.random_token, 24)
	if ok and type(t) == "string" and #t >= 16 and #t <= 64 and string.match(t, "^[%w]+$") then return t end
	-- запасной вариант, если random_token вернул что-то неожиданное
	local parts = {}
	for _ = 1, 32 do parts[#parts + 1] = string.format("%x", math.random(0, 15)) end
	return table.concat(parts)
end

-- handlers: on_event(kind, fields, line), on_ready(), on_down(), on_fatal(reason)
function agent.new(P, handlers)
	local self = setmetatable({}, agent)
	self.P = P
	self.h = handlers
	self.helper = nil
	self.port = nil
	self.token = nil
	self.ready = false
	self.fails = 0
	self.restart_in = 0
	self.alive_ticks = 0
	self.wanted = false
	self.fatal = false
	return self
end

function agent:start()
	self.wanted = true
	if self.helper or self.fatal then return end
	local P = self.P
	local okp, port = pcall(P.free_port)
	port = okp and util.int(port, 1024, 65535) or nil
	if not port then
		self.h.on_fatal("free_port")
		self.fatal = true
		return
	end
	self.port = port
	self.token = make_token(P)
	self.ready = false
	self.alive_ticks = 0
	local current
	local ok, h = pcall(P.run_helper, {
		native = "game_probe",
		args = { "--agent", tostring(port), self.token },
		elevate = false,
		on_output = function(line)
			if self.helper ~= current then return end
			self:_on_line(line)
		end,
		on_exit = function(code, note)
			if self.helper ~= current then return end
			P.log("agent exited code=" .. tostring(code) .. " note=" .. tostring(note))
			self.helper = nil
			local was_ready = self.ready
			self.ready = false
			if was_ready then self.h.on_down() end
			if self.wanted and not self.fatal then
				self.fails += 1
				self.restart_in = BACKOFF[math.min(self.fails, #BACKOFF)]
			end
		end,
	})
	if ok and h then
		self.helper = h
		current = h
	else
		local reason = string.match(tostring(h), "^[^\n]*") or "?"
		self.fatal = true
		self.h.on_fatal(reason)
	end
end

function agent:_on_line(line)
	local kind, f = util.parse_fields(line)
	if kind == "hello" then
		if tonumber(f.proto) ~= PROTO then
			self.fatal = true
			self:stop()
			self.h.on_fatal("proto " .. tostring(f.proto))
		else
			self.caps = {}
			for c in string.gmatch(f.caps or "", "[^,]+") do self.caps[c] = true end
		end
	elseif kind == "ready" then
		self.ready = true
		self.h.on_ready()
	elseif kind == "error" and f.reason == "bind" then
		-- порт успели занять между free_port и запуском: on_exit перезапустит на новом
		self.fails = math.max(self.fails - 1, 0)
	else
		self.h.on_event(kind, f, line)
	end
end

function agent:stop()
	self.wanted = false
	self.restart_in = 0
	local h = self.helper
	self.helper = nil
	if self.ready then
		self.ready = false
		self.h.on_down()
	end
	if h then pcall(function() h:stop() end) end
end

-- раз в тик: перезапуск после падения, сброс счётчика неудач
function agent:tick()
	if self.helper and self.ready then
		self.alive_ticks += 1
		if self.alive_ticks == STABLE_TICKS then self.fails = 0 end
	end
	if self.restart_in > 0 then
		self.restart_in -= 1
		if self.restart_in == 0 and self.wanted and not self.helper then self:start() end
	end
end

function agent:has(cap)
	return self.caps ~= nil and self.caps[cap] == true
end

-- отправить команду; false, если агент не готов
function agent:send(...)
	if not self.ready then return false end
	local parts = { self.token, ... }
	for i = 2, #parts do parts[i] = string.gsub(tostring(parts[i]), "[\t\r\n]", " ") end
	local ok = pcall(self.P.tcp_send, self.port, table.concat(parts, "\t") .. "\n")
	return ok
end

return agent
