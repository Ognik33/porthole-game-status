-- detect: какие локальные порты похожи на открытые миры (по списку on_listening и профилям игр)
local games = require("./games")

local detect = {}

-- list: записи on_listening {proto, program, port}
-- -> { [port] = { game = id, title = ..., kind = "strong"|"maybe" } }
function detect.scan(profiles, list)
	local found = {}
	for _, l in ipairs(list or {}) do
		if l.proto == "tcp" and type(l.program) == "string" then
			local port = tonumber(l.port)
			local id, kind = games.classify(profiles, l.program)
			if id and port and port >= 1 and port <= 65535 then
				local prev = found[port]
				if not prev or (prev.kind == "maybe" and kind == "strong") then
					found[port] = { game = id, title = l.program, kind = kind }
				end
			end
		end
	end
	return found
end

return detect
