-- util: небольшие общие функции без зависимостей от porthole
local util = {}

function util.nonempty(s)
	return type(s) == "string" and s ~= "" and s or nil
end

-- оставить только валидный UTF-8 без управляющих символов, обрезать до max байт по границе символа
function util.clean(s, max)
	if type(s) ~= "string" then return nil end
	s = string.gsub(s, "[%z\1-\31\127]", "")
	if utf8.len(s) == nil then return nil end
	if max and #s > max then
		local keep = 0
		for pos, code in utf8.codes(s) do
			local stop = pos - 1 + #utf8.char(code)
			if stop > max then break end
			keep = stop
		end
		s = string.sub(s, 1, keep)
	end
	return s
end

function util.int(s, lo, hi)
	local n = tonumber(s)
	if not n or n ~= math.floor(n) or n < lo or n > hi then return nil end
	return n
end

function util.ipv4(s)
	if type(s) ~= "string" then return nil end
	local a, b, c, d = string.match(s, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	for _, x in ipairs({ a, b, c, d }) do
		local n = tonumber(x)
		if n > 255 or (#x > 1 and string.sub(x, 1, 1) == "0") then return nil end
	end
	return s
end

-- "k=v<TAB>k=v" -> table; первое значение без "=" возвращается отдельно (тип строки)
function util.parse_fields(s)
	local kind, fields = nil, {}
	for part in string.gmatch(s, "[^\t]+") do
		local k, v = string.match(part, "^([^=]+)=(.*)$")
		if k then
			fields[k] = v
		elseif not kind then
			kind = part
		end
	end
	return kind, fields
end

function util.sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		if type(a) == type(b) then return a < b end
		return tostring(a) < tostring(b)
	end)
	return keys
end

return util
