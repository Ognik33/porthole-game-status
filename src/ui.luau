-- ui: плашки участников и вкладка. Никаких знаний о конкретных играх: только записи миров
--   запись: { g, p, ver, n, h, o, m, pl = {...}, j, lg }
local util = require("./util")

local ui = {}

local CAROUSEL_TICKS = 8 -- ~4 с

function ui.summary(w)
	local bits = {}
	if util.nonempty(w.ver) then bits[#bits + 1] = w.ver end
	if util.nonempty(w.n) then bits[#bits + 1] = w.n end
	if w.o and w.m then bits[#bits + 1] = w.o .. "/" .. w.m end
	return table.concat(bits, " · ")
end

function ui.new(P, t)
	-- вызовы интерфейса Porthole: ошибку не глотаем молча, а пишем в лог (один раз на текст ошибки)
	local logged = {}
	local function call(fn, spec, what)
		local ok, err = pcall(fn, spec)
		if not ok then
			local msg = what .. ": " .. tostring(err)
			if not logged[msg] then
				logged[msg] = true
				P.log(msg)
			end
		end
		return ok
	end

	local self = {
		P = P,
		t = t,
		shown = {},      -- member -> key -> { value, label }, что сейчас висит (обновляем только изменения)
		expanded = {},   -- port -> bool
		frame = 0,       -- кадр карусели
		frame_ticks = 0,
		has_multi = false,
	}

	-- значение плашки для миров одной игры
	local function plaque_value(list, carousel)
		if #list == 0 then return nil end
		if #list == 1 then return ui.summary(list[1]) end
		if carousel then
			local i = (self.frame % #list) + 1
			return i .. "/" .. #list .. " ▸ " .. ui.summary(list[i])
		end
		return ui.summary(list[1]) .. "  (+" .. (#list - 1) .. ")"
	end

	-- members: { {id=steam_id, worlds={записи}} }, labels: game -> подпись
	function self.plaques(members, labels, opts)
		self.has_multi = false
		local present = {}
		for _, m in ipairs(members) do
			present[m.id] = true
			local by_game, order = {}, {}
			for _, w in ipairs(m.worlds or {}) do
				if not by_game[w.g] then
					by_game[w.g] = {}
					order[#order + 1] = w.g
				end
				table.insert(by_game[w.g], w)
			end
			local was = self.shown[m.id] or {}
			local now = {}
			for _, g in ipairs(order) do
				if #by_game[g] > 1 then self.has_multi = true end
				local key = "game_" .. g
				local label = labels[g] or g
				local value = plaque_value(by_game[g], opts.carousel)
				local prev = was[key]
				if prev and prev.value == value and prev.label == label then
					now[key] = prev
				elseif call(P.ui.set_member_field, { member = m.id, key = key, label = label, value = value },
					"set_member_field") then
					now[key] = { value = value, label = label }
				end
			end
			for key, prev in pairs(was) do
				if now[key] == nil then
					-- снять плашку: Porthole ждёт полный набор полей, включая подпись, и value = nil
					if not call(P.ui.set_member_field, { member = m.id, key = key, label = prev.label, value = nil },
						"set_member_field (clear)") then
						now[key] = prev -- не удалось — попробуем снова при следующей отрисовке
					end
				end
			end
			self.shown[m.id] = now
		end
		for id in pairs(self.shown) do
			if not present[id] then self.shown[id] = nil end
		end
	end

	-- true, если пора перерисовать плашки (сменился кадр карусели)
	function self.tick(opts)
		if not (opts.carousel and self.has_multi) then return false end
		self.frame_ticks += 1
		if self.frame_ticks < CAROUSEL_TICKS then return false end
		self.frame_ticks = 0
		self.frame += 1
		return true
	end

	function self.reset()
		self.shown, self.expanded = {}, {}
	end

	-- model = { mine = { {port, world, rec, reason, checking} }, friends = { {who, rec, lan} },
	--           my_lan, can_copy, labels, opts, on_copy(text, done_key, vars) }
	function self.render(tab, model, rerender)
		local tree = {}
		local opts = model.opts
		local answered = 0
		for _, m in ipairs(model.mine) do if m.rec then answered += 1 end end

		if #model.mine == 0 then
			tree[#tree + 1] = { "status", "info", t("no_world") }
			tree[#tree + 1] = { "text", t("hint"), muted = true }
		elseif answered == 1 and #model.mine == 1 then
			local m = model.mine[1]
			tree[#tree + 1] = { "status", "ok", t("world_open", { game = model.labels[m.rec.g] or m.rec.g }) }
		elseif answered > 0 then
			tree[#tree + 1] = { "status", "ok", t("worlds_open", { n = tostring(answered) }) }
		end

		for i, m in ipairs(model.mine) do
			local port = m.port
			-- отступ между мирами: отдельного элемента для этого в Porthole нет, пустая строка текста
			if i > 1 then tree[#tree + 1] = { "text", " " } end
			if not m.rec then
				tree[#tree + 1] = { "status", "info", m.reason and t("unreachable") or t("checking") }
				tree[#tree + 1] = { "text", t("port") .. ": " .. port .. (m.reason and (" (" .. m.reason .. ")") or ""), muted = true }
			else
				local w = m.rec
				local open = self.expanded[port]
				if open == nil then open = #model.mine == 1 end
				local head = { "row", {
					"button",
					id = "w_" .. port,
					label = ui.summary(w) .. (open and "  ▾" or "  ▸"),
					on_press = function()
						self.expanded[port] = not open
						rerender()
					end,
				} }
				if w.lg then head[#head + 1] = { "chip", t("legacy") } end
				tree[#tree + 1] = head
				if open then
					local keys, vals = { "column" }, { "column" }
					local function add(k, v)
						if util.nonempty(v) then
							keys[#keys + 1] = { "text", k, muted = true }
							vals[#vals + 1] = { "text", v }
						end
					end
					if not opts.hide_names then add(t("host"), w.h) end
					if opts.show_players and not opts.hide_names and w.pl and #w.pl > 0 then
						add(t("players"), table.concat(w.pl, ", "))
					end
					add(t("port"), tostring(port))
					tree[#tree + 1] = { "row", keys, vals }
					if model.can_copy then
						local row = { "row", {
							"button", id = "copy_" .. port, label = t("copy_port"),
							on_press = function() model.on_copy(tostring(port), "copied_port", { port = tostring(port) }) end,
						} }
						if model.my_lan and w.j then
							local addr = model.my_lan .. ":" .. port
							row[#row + 1] = {
								"button", id = "copyaddr_" .. port, label = t("copy_addr", { addr = addr }),
								on_press = function() model.on_copy(addr, "copied_addr", { addr = addr }) end,
							}
						elseif model.my_lan then
							row[#row + 1] = { "chip", t("home_only") }
						end
						tree[#tree + 1] = row
					end
				end
			end
		end

		if #model.friends > 0 then
			if #model.mine > 0 then tree[#tree + 1] = { "text", " " } end
			tree[#tree + 1] = { "text", t("friends") .. ":" }
			for i, f in ipairs(model.friends) do
				if i > 1 then tree[#tree + 1] = { "text", " " } end
				local w = f.rec
				local who = opts.hide_names and t("someone") or (f.who or t("someone"))
				local label = model.labels[w.g] or w.g
				tree[#tree + 1] = { "text", "• " .. who .. ": " .. label .. " " .. ui.summary(w) }
				if f.lan and w.j and model.can_copy then
					local addr = f.lan .. ":" .. w.p
					tree[#tree + 1] = { "row", {
						"button", id = "peeraddr_" .. i .. "_" .. w.p, label = t("copy_addr", { addr = addr }),
						on_press = function() model.on_copy(addr, "copied_addr", { addr = addr }) end,
					} }
				elseif f.lan and w.j == false then
					tree[#tree + 1] = { "row", { "chip", t("home_only") } }
				end
			end
		end
		call(function(tr) return P.ui.render(tab, tr) end, tree, "render")
	end

	return self
end

return ui
