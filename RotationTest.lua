-- VoidSequencer — "Test my rotation".
-- Records one dummy fight and compares your casts per minute with the top players' (the
-- rates Rotations.lua ships per spec and hero tree), then builds a short report you can
-- paste into our Discord. It records only your own casts (UNIT_SPELLCAST_SUCCEEDED on
-- "player"), the game's error messages, and your damage from Blizzard's damage meter after
-- the fight. No combat log, no character name or realm in the report.
local _, ns = ...   -- ns.Move (VoidMove.lua)
local ADDON, VS = ...

local MIN_SECONDS = 60      -- shorter tests say little; the card says so
local PRE_SECONDS = 3       -- casts this long before combat starts count (an opener in flight)
local ROWS = 16

local DISCLOSURE = "Rotations are built from top players' combat logs and tuned with Claude, an AI "
	.. "assistant made by Anthropic. Reports you share in our Discord are read by Claude and the "
	.. "developer. A report has your spec, talents and casts, never your character name or realm."

local function Secret(v) return issecretvalue and issecretvalue(v) end

local test = { state = "idle" }   -- idle -> armed -> running -> done

----------------------------------------------------------------------
-- Top players' rates for the current spec, hero tree and mode
----------------------------------------------------------------------
local function TopRates(mode)
	local specID = VS.CurrentSpecID and VS.CurrentSpecID()
	local g = specID and VS.GenRotations and VS.GenRotations[specID]
	if not g then return nil end
	local hero = VS.ActiveHero and VS.ActiveHero()
	local r = (hero and g[hero])
	if not r then   -- no data for this hero tree: the first one, flagged
		for name, x in pairs(g) do if not r then r, hero = x, name end end
		test.otherHero = hero
	end
	return r and (mode == "AOE" and r.aoeRate or r.stRate), hero
end

-- The name a cast counts under: the spell itself if the top players' list has it, else
-- the button it morphed from (Vampiric Strike -> Scourge Strike).
local function CastName(id, rates)
	local name = C_Spell.GetSpellName(id)
	if not name or Secret(name) then return nil end
	if rates and rates[name] then return name end
	local base = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(id)
	local bname = base and base ~= id and C_Spell.GetSpellName(base)
	if bname and rates and rates[bname] then return bname end
	return name
end

----------------------------------------------------------------------
-- Recording
----------------------------------------------------------------------
local ev = CreateFrame("Frame")

-- The newest damage-meter session: its ID and length.
local function NewestSession()
	if not (C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions) then return nil end
	local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
	if not ok or type(sessions) ~= "table" then return nil end
	local newest, dur
	for _, s in ipairs(sessions) do
		local id = s.sessionID
		if type(id) == "number" and not Secret(id) and (not newest or id > newest) then newest, dur = id, s.durationSeconds end
	end
	return newest, dur
end

local function Reset()
	test.casts, test.fails, test.seen = {}, {}, {}
	test.start, test.stop, test.damage, test.otherHero, test.snap, test.pre = nil, nil, nil, nil, nil, nil
	test.mode = VS.IsAoE and VS.IsAoE() and "AOE" or "ST"
	test.rates, test.hero = TopRates(test.mode)
	test.sessionBefore = NewestSession() or 0   -- the fight's session must be newer than this
end

local function ReadDamage()
	if not (C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromID) then return end
	local newest, dur = NewestSession()
	if not newest or newest <= test.sessionBefore or type(dur) ~= "number" or Secret(dur) or dur <= 0 then return end
	local ok2, src = pcall(C_DamageMeter.GetCombatSessionSourceFromID, newest, Enum.DamageMeterType.DamageDone, UnitGUID("player"))
	if not ok2 or type(src) ~= "table" then return end
	local total = 0
	for _, sp in ipairs(src.combatSpells or {}) do
		local amt = sp.totalAmount
		if type(amt) == "number" and not Secret(amt) then total = total + amt end
	end
	if total > 0 then test.damage, test.damageSecs = total, dur end
end

local Finish, Refresh, Snapshot   -- forward

ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
	if event == "PLAYER_REGEN_DISABLED" then
		if test.state == "armed" then
			test.state, test.start = "running", GetTime()
			-- the spec, hero tree and mode the fight is fought in, not the ones at arming
			test.otherHero = nil
			test.mode = VS.IsAoE and VS.IsAoE() and "AOE" or "ST"
			test.rates, test.hero = TopRates(test.mode)
			-- an opener can land before combat starts (a projectile in flight): casts
			-- from just before count, and the fight starts at the first one
			for _, p in ipairs(test.pre or {}) do
				if test.start - p.t <= PRE_SECONDS then
					local name = CastName(p.id, test.rates)
					if name then test.casts[name] = (test.casts[name] or 0) + 1 end
					if p.t < test.start then test.start = p.t end
				end
			end
			test.pre = nil
			Refresh()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if test.state == "running" then
			-- stop counting now; the meter needs a moment to store the fight
			test.state, test.stop = "finishing", GetTime()
			Snapshot()   -- spec, talents and rotation as fought, before anything can change
			C_Timer.After(1, function() ReadDamage(); Finish() end)
		end
	elseif test.state == "armed" and event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- kept a few seconds in case it's the opener (counted at combat start)
		local guid, id = a2, a3
		if Secret(id) or Secret(guid) or not id then return end
		if guid then
			if test.seen[guid] then return end
			test.seen[guid] = true
		end
		test.pre = test.pre or {}
		table.insert(test.pre, { t = GetTime(), id = id })
		if #test.pre > 5 then table.remove(test.pre, 1) end
	elseif test.state ~= "running" then
		return
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local guid, id = a2, a3
		if Secret(id) or Secret(guid) or not id then return end
		if guid then
			if test.seen[guid] then return end   -- some spells report one press twice
			test.seen[guid] = true
		end
		local name = CastName(id, test.rates)
		if name then test.casts[name] = (test.casts[name] or 0) + 1 end
	elseif event == "UI_ERROR_MESSAGE" then
		local msg = a2
		if type(msg) == "string" and not Secret(msg) and msg ~= "" then test.fails[msg] = (test.fails[msg] or 0) + 1 end
	end
end)

local function Listen(on)
	for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "UI_ERROR_MESSAGE" }) do
		if on then ev:RegisterEvent(e) else ev:UnregisterEvent(e) end
	end
	if on then ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") else ev:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED") end
end

----------------------------------------------------------------------
-- Results
----------------------------------------------------------------------
-- One row per spell: the top players' spells first (by their rate), then yours they don't cast.
local function Rows()
	local mins = math.max((test.stop or GetTime()) - (test.start or GetTime()), 1) / 60
	local rows, have = {}, {}
	for name, top in pairs(test.rates or {}) do
		local n = test.casts[name] or 0
		local mine = n / mins
		local row = { name = name, mine = mine, top = top }
		local expected = top * mins
		if not (VS.SpellKnown and VS.SpellKnown(name)) and n == 0 then
			row.color, row.note = "888888", "not in your talents"
		elseif expected < 2 then   -- long cooldowns: a short test can't time them
			if n > 0 or expected < 1 then row.color, row.note = "55ff55", "cooldown"
			else row.color, row.note = "ffaa33", "not cast" end
		elseif n == 0 then
			row.color, row.note = "ff5555", "never cast"
		elseif mine / top < 0.75 then
			row.color, row.note = "ffaa33", "low"
		elseif mine / top > 1.33 then
			row.color, row.note = "ffaa33", "high"
		else
			row.color, row.note = "55ff55", "ok"
		end
		rows[#rows + 1] = row
		have[name] = true
	end
	table.sort(rows, function(a, b) return a.top > b.top end)
	local extra = {}
	for name, n in pairs(test.casts) do
		if not have[name] then extra[#extra + 1] = { name = name, mine = n / mins, color = "aaaaaa", note = "extra" } end
	end
	table.sort(extra, function(a, b) return a.mine > b.mine end)
	for _, r in ipairs(extra) do rows[#rows + 1] = r end
	return rows, mins
end

local function StepsText(steps)
	local out = {}
	for _, step in ipairs(steps or {}) do
		local parts = {}
		for _, sp in ipairs(step) do if sp and sp ~= "" then parts[#parts + 1] = sp end end
		out[#out + 1] = table.concat(parts, " > ")
	end
	return table.concat(out, " | ")
end

local function TalentString()
	local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
	local ok, s = pcall(function() return cfg and C_Traits.GenerateImportString(cfg) end)
	return ok and type(s) == "string" and s or "?"
end

-- What was tested, taken when the fight ends: a later spec, talent or edit change must
-- not change the report.
Snapshot = function()
	local _, specName = GetSpecializationInfo(GetSpecialization() or 0)
	local rev, gen = 0, false
	if VS.RotationRev then rev, gen = VS.RotationRev() end
	local steps = StepsText(VS.Seq and VS.Seq(test.mode))
	test.snap = {
		spec = specName or "?", specID = VS.CurrentSpecID and VS.CurrentSpecID() or "?",
		hero = VS.ActiveHero and VS.ActiveHero() or "no hero tree", rev = rev, gen = gen,
		steps = steps, edited = steps ~= StepsText(VS.DefaultSteps and VS.DefaultSteps(test.mode)),
		talents = TalentString(), level = UnitLevel("player"),
		ilvl = math.floor((select(2, GetAverageItemLevel())) or 0),
	}
end

-- The text pasted into Discord. Plain lines, so people and the bot can both read it; kept
-- under Discord's 2000-character message limit.
local function ReportText()
	local rows, mins = Rows()
	local s = test.snap
	local total = 0
	for _, n in pairs(test.casts) do total = total + n end
	local lines = {}
	lines[#lines + 1] = ("VSEQ-REPORT v1 | VoidSequencer %s | %s (%s) %s | %s | rotation %s%s"):format(
		C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?", s.spec, tostring(s.specID), s.hero, test.mode,
		tostring(s.rev), s.gen and " (generated)" or "")
	if test.otherHero then lines[#lines + 1] = "top numbers from: " .. test.otherHero .. " (none for this hero tree)" end
	lines[#lines + 1] = ("fight %ds | %s | %.1f casts/min | level %d | ilvl %d"):format(
		math.floor(mins * 60 + 0.5), test.damage and ("%.1fk dps"):format(test.damage / test.damageSecs / 1000) or "dps n/a",
		total / mins, s.level, s.ilvl)
	local parts = {}
	for _, r in ipairs(rows) do
		parts[#parts + 1] = r.top and ("%s %.1f/%.1f"):format(r.name, r.mine, r.top) or ("%s %.1f/-"):format(r.name, r.mine)
	end
	lines[#lines + 1] = "casts/min (you/top): " .. table.concat(parts, ", ")
	local f = {}
	for msg, n in pairs(test.fails) do f[#f + 1] = { msg = msg, n = n } end
	table.sort(f, function(a, b) return a.n > b.n end)
	local fp = {}
	for i = 1, math.min(5, #f) do fp[#fp + 1] = ("%s %.1f"):format(f[i].msg, f[i].n / mins) end
	lines[#lines + 1] = "errors/min: " .. (#fp > 0 and table.concat(fp, ", ") or "none")
	lines[#lines + 1] = "edited: " .. (s.edited and "yes" or "no")
	if s.edited then lines[#lines + 1] = "steps: " .. s.steps end
	lines[#lines + 1] = "talents: " .. s.talents
	local text = table.concat(lines, "\n")
	if #text > 1900 then text = text:sub(1, 1880) .. " ...(cut)" end
	return text
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local win, copyWin

local function CopyWindow()
	if copyWin then return copyWin end
	local f = CreateFrame("Frame", "VoidSeqReportCopy", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(520, 330); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
	f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
	ns.Move(f, { db = function() return VoidSequencerDB end, key = "reportCopy" })   -- drag + kept after a restart (VoidMove.lua)
	f.TitleText:SetText("Copy your report")
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 14, -32); hint:SetWidth(490); hint:SetJustifyH("LEFT")
	hint:SetText("Press Ctrl+C, then paste it in #rotation-reports on our Discord with a line about how it felt.")
	local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 14, -52); sf:SetPoint("BOTTOMRIGHT", -32, 70)
	local eb = CreateFrame("EditBox", nil, sf)
	eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject("ChatFontSmall"); eb:SetWidth(460)
	eb:SetScript("OnEscapePressed", function() f:Hide() end)
	sf:SetScrollChild(eb)
	f.edit = eb
	local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("BOTTOMLEFT", 14, 14); note:SetWidth(490); note:SetJustifyH("LEFT")
	note:SetText(DISCLOSURE)
	copyWin = f
	return f
end

local function ShowCopy()
	local f = CopyWindow()
	f.edit:SetText(ReportText())
	f:Show()
	f.edit:SetFocus(); f.edit:HighlightText()
end

local function Window()
	if win then return win end
	local f = CreateFrame("Frame", "VoidSeqTestWindow", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(430, 140 + ROWS * 16); f:SetPoint("CENTER", 260, 0)
	f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
	ns.Move(f, { db = function() return VoidSequencerDB end, key = "testWindow" })   -- drag + kept after a restart (VoidMove.lua)
	f.TitleText:SetText("VoidSequencer: Test my rotation")
	f.head = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.head:SetPoint("TOPLEFT", 14, -32); f.head:SetWidth(400); f.head:SetJustifyH("LEFT")
	-- The table hangs under the header, however many lines the header wraps to.
	f.colHead = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.colHead:SetPoint("TOPLEFT", f.head, "BOTTOMLEFT", 2, -10)
	f.colHead:SetText("Spell                                          you / min     top / min")
	f.rows = {}
	for i = 1, ROWS do
		local r = {}
		r.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.name:SetPoint("TOPLEFT", f.colHead, "BOTTOMLEFT", 0, -4 - (i - 1) * 16); r.name:SetWidth(170); r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
		r.mine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.mine:SetPoint("TOPLEFT", r.name, "TOPLEFT", 174, 0); r.mine:SetWidth(50); r.mine:SetJustifyH("RIGHT")
		r.top = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.top:SetPoint("TOPLEFT", r.name, "TOPLEFT", 229, 0); r.top:SetWidth(50); r.top:SetJustifyH("RIGHT")
		r.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.note:SetPoint("TOPLEFT", r.name, "TOPLEFT", 294, 0); r.note:SetWidth(110); r.note:SetJustifyH("LEFT")
		f.rows[i] = r
	end
	f.start = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.start:SetSize(110, 22); f.start:SetPoint("BOTTOMLEFT", 12, 12)
	f.copy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.copy:SetSize(110, 22); f.copy:SetPoint("LEFT", f.start, "RIGHT", 8, 0); f.copy:SetText("Copy report")
	f.copy:SetScript("OnClick", ShowCopy)
	f.copy:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Copy report")
		GameTooltip:AddLine(DISCLOSURE, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	f.copy:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f:SetScript("OnHide", function()
		if test.state == "armed" then test.state = "idle"; Listen(false) end
	end)
	win = f
	return f
end

Refresh = function()
	local f = Window()
	for _, r in ipairs(f.rows) do r.name:SetText(""); r.mine:SetText(""); r.top:SetText(""); r.note:SetText("") end
	f.colHead:SetShown(test.state == "done")
	f.copy:SetShown(test.state == "done")
	if test.state == "armed" then
		f.head:SetText("Ready. Attack a training dummy in " .. (test.mode == "AOE" and "AoE" or "single-target")
			.. " mode for 2-3 minutes. The test starts when combat starts and ends when combat ends.")
		f.start:SetText("Cancel")
		f.start:SetScript("OnClick", function() test.state = "idle"; Listen(false); Refresh() end)
	elseif test.state == "running" or test.state == "finishing" then
		f.head:SetText("Recording... leave combat to finish.")
		f.start:SetText("Recording"); f.start:SetScript("OnClick", nil)
	elseif test.state == "done" then
		local rows, mins = Rows()
		local secs = math.floor(mins * 60 + 0.5)
		local head = ("%s, %ds"):format(test.mode == "AOE" and "AoE" or "Single target", secs)
		if test.damage then head = head .. (", |cffffffff%.1fk|r damage per second"):format(test.damage / test.damageSecs / 1000) end
		if secs < MIN_SECONDS then head = head .. "\n|cffffaa33Short test: numbers are rough. 2-3 minutes is best.|r" end
		if not test.rates then
			head = head .. "\n|cff888888No top-player numbers for this spec yet: your casts only.|r"
		elseif test.otherHero then
			head = head .. ("\n|cffffaa33No numbers for your hero tree; compared with %s.|r"):format(test.otherHero)
		end
		f.head:SetText(head)
		for i, row in ipairs(rows) do
			local r = f.rows[i]
			if not r then break end
			r.name:SetText(row.name)
			r.mine:SetText(("%.1f"):format(row.mine))
			r.top:SetText(row.top and ("%.1f"):format(row.top) or "-")
			r.note:SetText("|cff" .. row.color .. row.note .. "|r")
		end
		f.start:SetText("Test again")
		f.start:SetScript("OnClick", function() VS.StartRotationTest() end)
	else
		f.head:SetText("Hit a training dummy for 2-3 minutes. You'll see each spell's casts per minute next to the top players' for your spec and hero tree.")
		f.start:SetText("Start test")
		f.start:SetScript("OnClick", function() VS.StartRotationTest() end)
	end
	-- header + table + buttons
	local shown = 0
	for _, r in ipairs(f.rows) do if (r.name:GetText() or "") ~= "" then shown = shown + 1 end end   -- a cleared FontString reads nil
	f:SetHeight(32 + f.head:GetStringHeight() + (test.state == "done" and (26 + shown * 16) or 0) + 50)
	f:Show()
end

Finish = function()
	if test.state ~= "finishing" then return end
	test.state = "done"
	Listen(false)   -- the snapshot was taken when combat ended
	Refresh()
end

function VS.StartRotationTest()
	if InCombatLockdown() then
		print("|cffcc66ffVoidSequencer|r leave combat first, then start the test.")
		return
	end
	-- the top players' rates are keyed by English spell names (as are the rotations'
	-- macros): another client language would compare nothing and show zeros
	local loc = GetLocale and GetLocale()
	if loc and loc ~= "enUS" and loc ~= "enGB" then
		print("|cffcc66ffVoidSequencer|r the rotation test needs an English game client for now.")
		return
	end
	Reset()
	test.state = "armed"
	Listen(true)
	Refresh()
end

function VS.OpenRotationTest()
	if test.state == "idle" or test.state == "done" then Refresh() else Window():Show() end
end

SLASH_VSTEST1 = "/vstest"
SlashCmdList["VSTEST"] = function() VS.OpenRotationTest() end
