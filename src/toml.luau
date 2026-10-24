-- toml: маленький парсер подмножества TOML для games.toml
-- поддерживает: [секция], ключ = "строка" | 'строка' | число | true/false | ["массив", "строк"], комментарии #
local toml = {}

local function parse_string(src, i)
	local q = string.sub(src, i, i)
	local out, j = {}, i + 1
	while j <= #src do
		local ch = string.sub(src, j, j)
		if ch == q then return table.concat(out), j + 1 end
		if ch == "\\" and q == '"' then
			local nx = string.sub(src, j + 1, j + 1)
			local map = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }
			if not map[nx] then error("bad escape \\" .. nx) end
			out[#out + 1] = map[nx]
			j += 2
		elseif ch == "\n" then
			error("unterminated string")
		else
			out[#out + 1] = ch
			j += 1
		end
	end
	error("unterminated string")
end

local function skip_ws(src, i)
	while true do
		local c = string.sub(src, i, i)
		if c == " " or c == "\t" then
			i += 1
		elseif c == "#" then
			while i <= #src and string.sub(src, i, i) ~= "\n" do i += 1 end
		else
			return i
		end
	end
end

local function parse_value(src, i)
	local c = string.sub(src, i, i)
	if c == '"' or c == "'" then return parse_string(src, i) end
	if c == "[" then
		local arr = {}
		i += 1
		while true do
			-- массив может занимать несколько строк
			while true do
				i = skip_ws(src, i)
				if string.sub(src, i, i) == "\n" or string.sub(src, i, i) == "\r" then i += 1 else break end
			end
			if string.sub(src, i, i) == "]" then return arr, i + 1 end
			local v
			v, i = parse_value(src, i)
			arr[#arr + 1] = v
			while true do
				i = skip_ws(src, i)
				if string.sub(src, i, i) == "\n" or string.sub(src, i, i) == "\r" then i += 1 else break end
			end
			local d = string.sub(src, i, i)
			if d == "," then
				i += 1
			elseif d ~= "]" then
				error("expected , or ]")
			end
		end
	end
	local word = string.match(src, "^[%w%.%-%+_]+", i)
	if not word then error("bad value") end
	if word == "true" then return true, i + #word end
	if word == "false" then return false, i + #word end
	local n = tonumber(word)
	if n == nil then error("bad value " .. word) end
	return n, i + #word
end

-- возвращает таблицу или nil, сообщение об ошибке (со строкой)
function toml.parse(src)
	local root, cur = {}, nil
	cur = root
	local i, line = 1, 1
	local ok, err = pcall(function()
		while i <= #src do
			i = skip_ws(src, i)
			local c = string.sub(src, i, i)
			if c == "\n" then
				line += 1
				i += 1
			elseif c == "\r" or c == "" then
				i += 1
			elseif c == "[" then
				local name = string.match(src, "^%[%s*([%w_%-%.]+)%s*%]", i)
				if not name then error("bad section") end
				cur = root
				for part in string.gmatch(name, "[^%.]+") do
					cur[part] = cur[part] or {}
					cur = cur[part]
				end
				i += #string.match(src, "^%[[^%]]*%]", i)
			else
				local key = string.match(src, "^[%w_%-]+", i)
				if not key then error("expected key") end
				i = skip_ws(src, i + #key)
				if string.sub(src, i, i) ~= "=" then error("expected =") end
				i = skip_ws(src, i + 1)
				local v
				local before = i
				v, i = parse_value(src, i)
				for _ in string.gmatch(string.sub(src, before, i - 1), "\n") do line += 1 end
				cur[key] = v
				i = skip_ws(src, i)
				local e = string.sub(src, i, i)
				if e ~= "\n" and e ~= "\r" and e ~= "" then error("junk after value") end
			end
		end
	end)
	if not ok then
		return nil, "line " .. line .. ": " .. tostring(err)
	end
	return root
end

return toml
