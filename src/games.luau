-- games: профили игр. Источник — games.toml в папке дополнения; если файла нет или он
-- с ошибкой, используются встроенные профили (те же самые), а ошибка пишется в лог.
local toml = require("./toml")
local util = require("./util")

local games = {}

local BUILTIN = {
	minecraft = {
		label = "Minecraft",
		adapter = "minecraft",
		strong = { "Minecraft" },
		maybe = { "MultiMC", "Prism Launcher", "PrismLauncher", "PolyMC", "ATLauncher", "TLauncher",
			"GDLauncher", "javaw.exe", "java.exe" },
		title_version = "Minecraft%*?%s+([%w%.%-]+)",
		instance_from_title = true,
	},
}

-- адаптеры, которые есть в game_probe этой версии
local KNOWN_ADAPTERS = { minecraft = true }

local function valid_profile(id, p)
	if type(p) ~= "table" then return nil end
	if not string.match(id, "^[a-z0-9_]+$") or #id > 16 then return nil end
	if type(p.adapter) ~= "string" or not KNOWN_ADAPTERS[p.adapter] then return nil end
	local function strings(list)
		local out = {}
		if type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "string" and s ~= "" then out[#out + 1] = s end
			end
		end
		return out
	end
	local prof = {
		label = util.clean(p.label, 32) or id,
		adapter = p.adapter,
		strong = strings(p.strong),
		maybe = strings(p.maybe),
		title_version = type(p.title_version) == "string" and p.title_version or nil,
		instance_from_title = p.instance_from_title == true,
	}
	if prof.title_version and not pcall(string.match, "", prof.title_version) then prof.title_version = nil end
	if #prof.strong == 0 and #prof.maybe == 0 then return nil end
	return prof
end

-- read: функция чтения файла (porthole.read_file), log: функция лога
function games.load(read, log)
	local ok, src = pcall(read, "games.toml")
	if not ok or type(src) ~= "string" then
		log("games.toml not readable, using built-in profiles")
		return BUILTIN
	end
	local data, err = toml.parse(src)
	if not data then
		log("games.toml: " .. tostring(err) .. "; using built-in profiles")
		return BUILTIN
	end
	local out, n = {}, 0
	for id, p in pairs(data) do
		local prof = valid_profile(id, p)
		if prof then
			out[id] = prof
			n += 1
		else
			log("games.toml: profile [" .. tostring(id) .. "] skipped (invalid or unknown adapter)")
		end
	end
	if n == 0 then
		log("games.toml has no usable profiles; using built-in profiles")
		return BUILTIN
	end
	return out
end

-- "strong" | "maybe" | nil для заголовка окна / имени программы
function games.classify(profiles, title)
	for _, id in ipairs(util.sorted_keys(profiles)) do
		local p = profiles[id]
		for _, pat in ipairs(p.strong) do
			if string.find(title, pat, 1, true) then return id, "strong" end
		end
	end
	for _, id in ipairs(util.sorted_keys(profiles)) do
		local p = profiles[id]
		for _, pat in ipairs(p.maybe) do
			if string.find(title, pat, 1, true) then return id, "maybe" end
		end
	end
	return nil
end

-- подпись версии из заголовка, если сервер её не сообщил
function games.title_version(prof, title)
	if not prof or not title then return nil end
	if prof.title_version then
		local v = string.match(title, prof.title_version)
		if v then return v end
	end
	if prof.instance_from_title and not string.find(title, ".exe", 1, true) then
		local inst = string.match(title, "^[^:]+:%s*(.-)%s*$")
		if inst and inst ~= "" then return inst end
	end
	return nil
end

return games
