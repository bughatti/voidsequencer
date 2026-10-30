-- VoidSequencer Options — Blizzard settings panel.
-- Houses the keybind, the Army-on-Alt toggle, and the guided ROTATION EDITOR:
-- a spell-picker (no macro syntax) for the ST and AoE sequences. Each step is a
-- priority stack of spells; the engine (VoidSequencer.lua) turns the picks into
-- the secure macro. All edits route through VS.* and re-apply via VS.Apply().
local ADDON, VS = ...

local panel = CreateFrame("Frame")
panel.name = "VoidSequencer"

local editMode = "ST"        -- which rotation the editor is showing
local RefreshList            -- forward decl (used by menus/popups below)
local pendingCustom          -- {step=, slot=} target for the custom-name popup
local pendingModMod          -- which modifier (alt/ctrl/shift) the mod custom-name popup targets

-- ---------------------------------------------------------------------------
-- Header
-- ---------------------------------------------------------------------------
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("VoidSequencer")

local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
sub:SetWidth(560)
sub:SetJustifyH("LEFT")
-- Text set dynamically per spec in RefreshHeader (below).
sub:SetText("One-button rotation sequencer. Spam your key; the ST/AoE switch picks the rotation.")

-- ---------------------------------------------------------------------------
-- Master enable toggle. OFF releases your key (restoring whatever was bound
-- there) so you can try VoidSequencer risk-free and revert instantly.
-- ---------------------------------------------------------------------------
local enableCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
enableCB:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -12)
enableCB.Text:SetText("Enable VoidSequencer  (binds your key + runs the rotation)")
enableCB.Text:SetFontObject("GameFontNormal")
enableCB:SetScript("OnClick", function(self)
	if VS.SetEnabled then VS.SetEnabled(self:GetChecked()) end
end)

-- (Priority mode, one step holding every spell, was removed 2026-10-30: a press makes one
-- on-GCD try, so it only ever tried the first spell.)

-- Cadence glow toggle. A green on-screen pulse that lights when you are off the
-- global cooldown -- tap your key in rhythm with it so fast mashing can't skip steps.
local pacerCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
pacerCB:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -6)
pacerCB.Text:SetText("Cadence glow  (lights up when a press will land -- tap in rhythm, don't over-mash)")
pacerCB.Text:SetFontObject("GameFontHighlight")
pacerCB:SetScript("OnClick", function(self)
	if VS.SetPacer then VS.SetPacer(self:GetChecked()) end
end)

-- On-screen ST/AoE switch. Right-clicking VoidSequencer's minimap/VoidHub icon also
-- hides it, which is easy to do by accident -- this is the visible way back.
local switchCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
switchCB:SetPoint("TOPLEFT", pacerCB, "BOTTOMLEFT", 0, -6)
switchCB.Text:SetText("Show the ST / AoE switch on screen")
switchCB.Text:SetFontObject("GameFontHighlight")
switchCB:SetScript("OnClick", function(self)
	if InCombatLockdown() then   -- the switch is a secure button: no show/hide in combat
		self:SetChecked(not self:GetChecked())
		print("|cffcc66ffVoidSequencer|r: leave combat to show or hide the switch.")
		return
	end
	local show = self:GetChecked() and true or false
	VoidSequencerDB.switchHidden = not show
	if VS.ApplyEnabled then VS.ApplyEnabled() end   -- the switch's visibility driver
end)

-- ---------------------------------------------------------------------------
-- Keybind row
-- ---------------------------------------------------------------------------
local kbLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
kbLabel:SetPoint("TOPLEFT", switchCB, "BOTTOMLEFT", 0, -12)
kbLabel:SetText("Rotation keybind:")

local kbCurrent = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
kbCurrent:SetPoint("LEFT", kbLabel, "RIGHT", 10, 0)

local kbButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
kbButton:SetSize(110, 22)
kbButton:SetPoint("LEFT", kbCurrent, "RIGHT", 14, 0)
kbButton:SetText("Set Keybind")
kbButton:SetScript("OnClick", function()
	kbCurrent:SetText("|cffffff00press a key...|r")
	if VS.CaptureKey then VS.CaptureKey() end
end)

-- Recommended talent builds: a single dropdown listing the hero x content builds for
-- your current spec (e.g. "Aldrachi Reaver (M+)", "Fel-scarred (Raid)"). Pick one and
-- it creates a saved loadout; you then select it in the talent UI and hit Apply. WoW
-- gates the actual apply behind a hardware click on the talent frame, so we can't (and
-- shouldn't) silently overwrite your talents. At lower level WoW trims to affordable
-- points. A dropdown keeps the panel clean instead of a button per build.
local buildLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
buildLabel:SetPoint("TOPLEFT", kbLabel, "BOTTOMLEFT", 0, -16)
buildLabel:SetText("Recommended talent build:")

local buildButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
buildButton:SetSize(240, 22)
buildButton:SetPoint("LEFT", buildLabel, "RIGHT", 10, 0)
do
	local bfs = buildButton:GetFontString()
	if bfs then bfs:SetFontObject("GameFontHighlightSmall"); bfs:SetWordWrap(false); bfs:SetWidth(228) end
end
-- Every spec of the player's class that has builds: { id, name, current, builds }.
local function ClassSpecBuilds()
	local out = {}
	local _, _, classID = UnitClass("player")
	local cur = C_SpecializationInfo.GetSpecialization()
	for i = 1, (C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0) do
		local id, name = C_SpecializationInfo.GetSpecializationInfo(i)
		local builds = id and VS.BuildsForSpec and VS.BuildsForSpec(id, name) or {}
		if #builds > 0 then out[#out + 1] = { id = id, name = name, current = (i == cur), builds = builds } end
	end
	return out
end

buildButton:SetScript("OnClick", function(self)
	local builds = (VS.RecommendedBuilds and VS.RecommendedBuilds()) or {}
	local specs = ClassSpecBuilds()
	if #builds == 0 and #specs == 0 then return end
	MenuUtil.CreateContextMenu(self, function(owner, root)
		-- one click: spec, talents and hero tree
		root:CreateTitle("Switch to a build (spec, talents, hero tree)")
		for _, sp in ipairs(specs) do
			local sub = root:CreateButton(sp.name .. (sp.current and "  (current)" or ""))
			for _, b in ipairs(sp.builds) do
				sub:CreateButton(b.name or "Build", function() VS.SwitchToBuild(sp.id, b) end)
			end
		end
		if #builds == 0 then return end
		root:CreateDivider()
		root:CreateTitle("Put a build on your current talents")
		for _, b in ipairs(builds) do
			root:CreateButton(b.name or "Build", function()
				if VS.StageBuild then VS.StageBuild(b.build, b.name) end
			end)
		end
		root:CreateDivider()
		local save = root:CreateButton("Save as a new loadout instead")
		for _, b in ipairs(builds) do
			save:CreateButton(b.name or "Build", function()
				if VS.ImportBuild then VS.ImportBuild(b.build, "VoidSeq " .. (b.name or "Build")) end
			end)
		end
	end)
end)
buildButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Recommended talent build")
	GameTooltip:AddLine("Switch to a build: one click changes spec (if needed), talents and hero tree. Out of combat.", 1, 1, 1, true)
	GameTooltip:AddLine("Put a build on your current talents: laid onto your talents, then open Talents (N) and click Apply Changes.", 1, 1, 1, true)
	GameTooltip:AddLine("Leveling: pick it again after each level-up to spend the new points. Points the build can't use yet go on open talents until it can.", 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end)
buildButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshBuildButtons()
	local n = 0
	for _, sp in ipairs(ClassSpecBuilds()) do n = n + #sp.builds end
	if n == 0 then
		buildButton:SetText("(no builds for your class yet)")
		buildButton:SetEnabled(false)
	else
		buildButton:SetText("Choose a build...  (" .. n .. ")")
		buildButton:SetEnabled(true)
	end
end

-- Modifier ability pickers (ALT / CTRL / SHIFT) ------------------------------
-- Held while you press your rotation key, each fires its assigned ability at any
-- point in the rotation. Seeded per spec, fully rebindable; heals keep their
-- mouseover targeting. Replaces the old hardcoded Army/Death-Pact checkboxes.
-- Rotation check: does the loaded rotation fit your current talents? Re-runs by itself
-- after a talent change; Details prints the full list in chat (also /vscheck).
-- Rotation picker: every rotation this spec can run. Tuned ones are hand-built; the
-- others are generated per hero tree from the top players' casts (Rotations.lua).
-- Automatic = tuned if there is one for your hero tree, else your hero tree's.
local rotLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
rotLabel:SetPoint("TOPLEFT", buildLabel, "BOTTOMLEFT", 0, -16)
rotLabel:SetText("Rotation:")

local rotButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
rotButton:SetSize(300, 22)
rotButton:SetPoint("LEFT", rotLabel, "RIGHT", 10, 0)
do
	local rfs = rotButton:GetFontString()
	if rfs then rfs:SetFontObject("GameFontHighlightSmall"); rfs:SetWordWrap(false); rfs:SetWidth(288) end
end
rotButton:SetScript("OnClick", function(self)
	local choices = VS.RotationChoices and VS.RotationChoices() or {}
	if #choices == 0 then return end
	local pick = VS.GetRotationPick and VS.GetRotationPick()
	MenuUtil.CreateContextMenu(self, function(owner, root)
		root:CreateTitle("Rotation for this spec")
		root:CreateRadio("Automatic (matches your hero tree)", function() return pick == nil end,
			function() VS.SetRotationPick(nil) end)
		root:CreateDivider()
		for _, c in ipairs(choices) do
			root:CreateRadio(c.label, function() return pick == c.key end, function() VS.SetRotationPick(c.key) end)
		end
	end)
end)
rotButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Rotation")
	GameTooltip:AddLine("Tuned: built and tested by hand. Top players (beta): built per hero tree from the best players' casts on a single-target boss (ST) and an add-heavy boss (AoE), not yet tested in game.", 1, 1, 1, true)
	GameTooltip:AddLine("Picking one replaces your edits to the current rotation.", 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end)
rotButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshRotationButton()
	local choices = VS.RotationChoices and VS.RotationChoices() or {}
	local cur = VS.CurrentSpec and VS.CurrentSpec()
	local text = "(no rotation for this spec yet)"
	for _, c in ipairs(choices) do
		if c.key == cur then text = c.label end
	end
	if not (VS.GetRotationPick and VS.GetRotationPick()) and #choices > 0 then text = "Auto: " .. text end
	rotButton:SetText(text)
	rotButton:SetEnabled(#choices > 0)
end

local checkLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
checkLabel:SetPoint("TOPLEFT", rotLabel, "BOTTOMLEFT", 0, -14)
checkLabel:SetText("Rotation check:")

local checkText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
checkText:SetPoint("LEFT", checkLabel, "RIGHT", 10, 0)
checkText:SetWidth(330); checkText:SetJustifyH("LEFT"); checkText:SetWordWrap(false)

local checkButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
checkButton:SetSize(70, 22)
checkButton:SetPoint("LEFT", checkText, "RIGHT", 8, 0)
checkButton:SetText("Details")
checkButton:SetScript("OnClick", function() if VS.PrintRotationCheck then VS.PrintRotationCheck() end end)
checkButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Rotation check")
	GameTooltip:AddLine("Compares the rotation with your talents: spells you don't have, steps that can't fire, talented abilities it never casts, and the hero tree it was built for. Full list goes to chat (/vscheck).", 1, 1, 1, true)
	GameTooltip:Show()
end)
checkButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshCheck()
	checkText:SetText(VS.RotationSummary and VS.RotationSummary() or "")
end

local modLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
modLabel:SetPoint("TOPLEFT", checkLabel, "BOTTOMLEFT", 0, -12)
modLabel:SetText("Modifier casts (hold the key while you press your rotation key):")

local modRows = {}
local function refreshModRows()
	for _, m in ipairs(modRows) do
		local cur = (VS.GetMod and VS.GetMod(m.key)) or ""
		m.btn:SetText(cur ~= "" and cur or "|cff888888(none)|r")
	end
end

local modAnchor = modLabel
for _, def in ipairs({
	{ key = "alt",   text = "Hold ALT" },
	{ key = "ctrl",  text = "Hold CTRL" },
	{ key = "shift", text = "Hold SHIFT" },
}) do
	local mk = def.key
	local row = CreateFrame("Frame", nil, panel)
	row:SetSize(420, 24)
	row:SetPoint("TOPLEFT", modAnchor, "BOTTOMLEFT", 0, -6)

	local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(80); lbl:SetJustifyH("LEFT")
	lbl:SetText(def.text)

	local arrow = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	arrow:SetPoint("LEFT", lbl, "RIGHT", 2, 0); arrow:SetText("->")

	local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	btn:SetSize(190, 22); btn:SetPoint("LEFT", arrow, "RIGHT", 8, 0)
	local bfs = btn:GetFontString()
	if bfs then bfs:SetFontObject("GameFontHighlightSmall"); bfs:SetWordWrap(false); bfs:SetWidth(180) end
	btn:SetScript("OnClick", function(self)
		MenuUtil.CreateContextMenu(self, function(owner, root)
			root:CreateTitle("Pick an ability for " .. def.text)
			root:CreateButton("|cff888888(none)|r", function() VS.SetMod(mk, ""); refreshModRows() end)
			root:CreateDivider()
			for _, name in ipairs(VS.SpellPool()) do
				root:CreateButton(name, function() VS.SetMod(mk, name); refreshModRows() end)
			end
			root:CreateDivider()
			root:CreateButton("Custom ability name...", function()
				pendingModMod = mk
				StaticPopup_Show("VOIDSEQ_MODCUSTOM")
			end)
		end)
	end)

	modRows[#modRows + 1] = { key = mk, btn = btn }
	modAnchor = row
end

-- Header refresh: dynamic subtitle (current spec) + modifier picker labels.
local function RefreshHeader()
	local spec = (VS.CurrentSpec and VS.CurrentSpec()) or ""
	sub:SetText("One-button rotation sequencer" .. (spec ~= "" and (" - " .. spec) or "")
		.. ". Spam your key; the ST/AoE switch picks the rotation.")
	refreshModRows()
end

-- ---------------------------------------------------------------------------
-- Rotation editor: ST / AoE tabs
-- ---------------------------------------------------------------------------
local edLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
edLabel:SetPoint("TOPLEFT", modAnchor, "BOTTOMLEFT", 0, -14)
edLabel:SetText("Rotation editor — pick the spells for each step (top = highest priority):")

local tabST = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
tabST:SetSize(110, 22)
tabST:SetPoint("TOPLEFT", edLabel, "BOTTOMLEFT", 0, -8)
tabST:SetText("Single Target")

local tabAOE = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
tabAOE:SetSize(110, 22)
tabAOE:SetPoint("LEFT", tabST, "RIGHT", 6, 0)
tabAOE:SetText("AoE")

local defBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
defBtn:SetSize(130, 22)
defBtn:SetPoint("LEFT", tabAOE, "RIGHT", 24, 0)
defBtn:SetText("Restore Defaults")

local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", tabST, "BOTTOMLEFT", 0, -4)
hint:SetWidth(560)
hint:SetJustifyH("LEFT")
hint:SetText("Each step casts the first ready spell; extras are fallbacks. Edits apply instantly (or when you leave combat).")

local function tabVisual()
	tabST:SetEnabled(editMode ~= "ST")
	tabAOE:SetEnabled(editMode ~= "AOE")
end

-- ---------------------------------------------------------------------------
-- Scrollable step list
-- ---------------------------------------------------------------------------
-- Add Step is pinned near the panel's bottom, and the scroll frame fills the space
-- between the hint above and that button below. This way both stay on-screen no matter
-- how much sits above (build row, modifiers), and the scrollbar's down-arrow never
-- collides with the window's bottom chrome -- the list just gets shorter and scrolls.
local addStepBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
addStepBtn:SetSize(120, 22)
addStepBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
addStepBtn:SetText("+ Add Step")
addStepBtn:SetScript("OnClick", function()
	VS.AddStep(editMode)
	VS.Apply()
	RefreshList()
end)

local scroll = CreateFrame("ScrollFrame", "VoidSeqEditScroll", panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
scroll:SetPoint("BOTTOMLEFT", addStepBtn, "TOPLEFT", 0, 12)
scroll:SetWidth(560)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(536, 10)
scroll:SetScrollChild(content)

local rows = {}  -- pooled step-row frames

-- Open the spell-picker menu for a tile (one spell slot in a step).
local function openSpellMenu(tile)
	local r = tile.row
	local stepIdx, slotIdx = r.index, tile.slot
	MenuUtil.CreateContextMenu(tile, function(owner, root)
		root:CreateTitle("Pick a spell")
		for _, name in ipairs(VS.SpellPool()) do
			root:CreateButton(name, function()
				VS.SetSpell(editMode, stepIdx, slotIdx, name); VS.Apply(); RefreshList()
			end)
		end
		root:CreateDivider()
		root:CreateButton("Custom spell name...", function()
			pendingCustom = { step = stepIdx, slot = slotIdx }
			StaticPopup_Show("VOIDSEQ_CUSTOM")
		end)
		if #VS.Seq(editMode)[stepIdx] > 1 then
			root:CreateButton("|cffff5555Remove this spell|r", function()
				VS.RemoveSpell(editMode, stepIdx, slotIdx); VS.Apply(); RefreshList()
			end)
		end
	end)
end

local function acquireTile(r, j)
	local t = r.tiles[j]
	if not t then
		t = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
		t:SetSize(108, 22)
		t.row = r
		-- keep long names (e.g. "Dark Transformation") inside the button: small
		-- font, no wrap, clamped to the tile width so it truncates instead of spilling.
		local fs = t:GetFontString()
		if fs then
			fs:SetFontObject("GameFontHighlightSmall")
			fs:SetWordWrap(false)
			fs:SetWidth(100)
		end
		t:SetScript("OnClick", function(self) openSpellMenu(self) end)
		r.tiles[j] = t
	end
	return t
end

local function acquireRow(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Frame", nil, content)
	r:SetSize(536, 28)
	r.tiles = {}

	-- a dark strip behind each row so spell tiles read cleanly over the world
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetPoint("TOPLEFT", 0, 0)
	r.bg:SetPoint("BOTTOMRIGHT", 0, 2)

	r.num = r:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	r.num:SetPoint("LEFT", 0, 0); r.num:SetWidth(26); r.num:SetJustifyH("RIGHT")

	r.up = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	r.up:SetSize(30, 20); r.up:SetText("Up"); r.up:SetPoint("LEFT", r.num, "RIGHT", 6, 0)
	r.up:SetScript("OnClick", function() VS.MoveStep(editMode, r.index, -1); VS.Apply(); RefreshList() end)

	r.dn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	r.dn:SetSize(30, 20); r.dn:SetText("Dn"); r.dn:SetPoint("LEFT", r.up, "RIGHT", 2, 0)
	r.dn:SetScript("OnClick", function() VS.MoveStep(editMode, r.index, 1); VS.Apply(); RefreshList() end)

	r.del = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	r.del:SetSize(34, 20); r.del:SetText("Del"); r.del:SetPoint("LEFT", r.dn, "RIGHT", 2, 0)
	r.del:SetScript("OnClick", function()
		if #VS.Seq(editMode) > 1 then VS.RemoveStep(editMode, r.index); VS.Apply(); RefreshList() end
	end)

	r.add = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
	r.add:SetSize(54, 20); r.add:SetText("+ Spell")
	r.add:SetScript("OnClick", function() VS.AddSpell(editMode, r.index, ""); RefreshList() end)

	rows[i] = r
	return r
end

RefreshList = function()
	local seq = VS.Seq(editMode)
	if not seq then return end
	local y = 4
	for i, step in ipairs(seq) do
		local r = acquireRow(i)
		r.index = i
		r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.05 or 0.10)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
		r:Show()
		r.num:SetText(i .. ".")
		for _, t in ipairs(r.tiles) do t:Hide() end
		local tx = 140  -- clear of num + Up/Dn/Del
		for j, spell in ipairs(step) do
			local t = acquireTile(r, j)
			t.slot = j
			t:SetText(spell ~= "" and spell or "|cff999999(pick)|r")
			t:ClearAllPoints(); t:SetPoint("LEFT", r, "LEFT", tx, 0)
			t:Show()
			tx = tx + 112
		end
		r.add:ClearAllPoints(); r.add:SetPoint("LEFT", r, "LEFT", tx, 0)
		y = y + 30
	end
	for i = #seq + 1, #rows do rows[i]:Hide() end
	content:SetHeight(y + 10)
	RefreshCheck()   -- an edit can add or drop a spell you don't have
end

local function RefreshAll()
	RefreshHeader()
	tabVisual()
	RefreshList()
end

tabST:SetScript("OnClick", function() editMode = "ST"; RefreshAll() end)
tabAOE:SetScript("OnClick", function() editMode = "AOE"; RefreshAll() end)
defBtn:SetScript("OnClick", function()
	if VS.Defaults then VS.Defaults(editMode); RefreshList() end
end)

-- Custom-spell-name popup (covers spells not on your bars / not yet in rotation).
StaticPopupDialogs["VOIDSEQ_CUSTOM"] = {
	text = "Enter the exact spell name:",
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true,
	OnAccept = function(self)
		local box = self.editBox or self:GetEditBox()
		local txt = (box:GetText() or ""):gsub("[\r\n%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if txt ~= "" and pendingCustom then
			VS.SetSpell(editMode, pendingCustom.step, pendingCustom.slot, txt)
			VS.Apply(); RefreshList()
		end
		pendingCustom = nil
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent().button1:Click() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

-- Custom ability-name popup for a modifier slot (ALT/CTRL/SHIFT).
StaticPopupDialogs["VOIDSEQ_MODCUSTOM"] = {
	text = "Enter the exact ability name for this modifier:",
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true,
	OnAccept = function(self)
		local box = self.editBox or self:GetEditBox()
		local txt = (box:GetText() or ""):gsub("[\r\n%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if pendingModMod then VS.SetMod(pendingModMod, txt); if refreshModRows then refreshModRows() end end
		pendingModMod = nil
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent().button1:Click() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

-- ---------------------------------------------------------------------------
-- Keybind display refresh (kept from the old panel) + show hook
-- ---------------------------------------------------------------------------
local function RefreshOptions()
	local k = VS.GetKey and VS.GetKey()
	kbCurrent:SetText(k and ("|cff55ff55" .. k .. "|r") or "|cffff5555unbound|r")
	if VS.GetEnabled then enableCB:SetChecked(VS.GetEnabled()) end

	if VS.GetPacer then pacerCB:SetChecked(VS.GetPacer()) end
	switchCB:SetChecked(not (VoidSequencerDB and VoidSequencerDB.switchHidden))
	RefreshBuildButtons()
	RefreshRotationButton()
	RefreshCheck()
	if panel:IsShown() then RefreshAll() end   -- a new rotation pick refills the editor
end
VS.RefreshOptions = RefreshOptions
panel:SetScript("OnShow", function()
	RefreshOptions()
	RefreshAll()
end)

-- ---------------------------------------------------------------------------
-- Register the panel
-- ---------------------------------------------------------------------------
local category
if Settings and Settings.RegisterCanvasLayoutCategory then
	category = Settings.RegisterCanvasLayoutCategory(panel, "VoidSequencer")
	Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
	InterfaceOptions_AddCategory(panel)
end

function VS.OpenOptions()
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID()) -- numeric ID, not the name
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(panel)
		InterfaceOptionsFrame_OpenToCategory(panel) -- twice: Blizzard quirk
	end
end

-- Slash fallback (the minimap icon is the primary entry point).
SLASH_VOIDSEQ1 = "/vseq"
SLASH_VOIDSEQ2 = "/voidsequencer"
SlashCmdList["VOIDSEQ"] = function() VS.OpenOptions() end
