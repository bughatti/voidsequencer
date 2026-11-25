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
pacerCB.Text:SetText("Cadence glow")
pacerCB.Text:SetFontObject("GameFontHighlight")
pacerCB:SetScript("OnClick", function(self)
	if VS.SetPacer then VS.SetPacer(self:GetChecked()) end
end)

-- On-screen ST/AoE switch. Right-clicking VoidSequencer's minimap/VoidHub icon also
-- hides it, which is easy to do by accident -- this is the visible way back.
local switchCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
switchCB:SetPoint("LEFT", pacerCB, "LEFT", 300, 0)   -- placed beside the cadence box below (room for the editor)
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
kbLabel:SetPoint("TOPLEFT", pacerCB, "BOTTOMLEFT", 0, -12)
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
		-- one click: spec, talents and hero tree (none in WoW Forever)
		if #specs > 0 then
			root:CreateTitle("Switch to a build (spec, talents, hero tree)")
			for _, sp in ipairs(specs) do
				local sub = root:CreateButton(sp.name .. (sp.current and "  (current)" or ""))
				for _, b in ipairs(sp.builds) do
					sub:CreateButton(b.name or "Build", function() VS.SwitchToBuild(sp.id, b) end)
				end
			end
		end
		if #builds == 0 then return end
		if #specs > 0 then root:CreateDivider() end
		root:CreateTitle("Put a build on your current talents")
		for _, b in ipairs(builds) do
			root:CreateButton(b.name or "Build", function()
				if VS.StageBuild then VS.StageBuild(b.build, b.name) end
			end)
		end
		-- Only import-string builds can become a saved loadout (Forever's are node lists).
		local strings = {}
		for _, b in ipairs(builds) do if type(b.build) == "string" then strings[#strings + 1] = b end end
		if #strings == 0 then return end
		root:CreateDivider()
		local save = root:CreateButton("Save as a new loadout instead")
		for _, b in ipairs(strings) do
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
	GameTooltip:AddLine("Put a build on your current talents: laid onto your talents and applied. Out of combat, stand still for the cast.", 1, 1, 1, true)
	GameTooltip:AddLine("Leveling: pick it again after each level-up to spend the new points. Points the build can't use yet go on open talents until it can.", 0.7, 0.7, 0.7, true)
	GameTooltip:Show()
end)
buildButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshBuildButtons()
	local n = 0
	for _, sp in ipairs(ClassSpecBuilds()) do n = n + #sp.builds end
	-- WoW Forever has no switch list, only the current class's builds
	if n == 0 and VS.RecommendedBuilds then n = #VS.RecommendedBuilds() end
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
	if rfs then rfs:SetWordWrap(false); rfs:SetWidth(288) end   -- (a font set here is undone by the template on enable/disable)
end
-- a tooltip on any control: title + plain-words lines (the user, 2026-11-25: "it needs to be easy for players to
-- figure out, even if we need to add tooltips")
local function tip(frame, title, ...)
	local lines = { ... }
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(title)
		for _, l in ipairs(lines) do GameTooltip:AddLine(l, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end
local function menuTip(el, title, text)
	if el and el.SetTooltip then
		el:SetTooltip(function(t) GameTooltip_SetTitle(t, title); GameTooltip_AddNormalLine(t, text) end)
	end
end
local ShowTextDialog, pendingName   -- defined below (shared text window, name prompt)

rotButton:SetScript("OnClick", function(self)
	local choices = VS.RotationChoices and VS.RotationChoices() or {}
	local pick = VS.GetRotationPick and VS.GetRotationPick()
	local mineName = VS.MineActive and VS.MineActive()
	local list = VS.MineList and VS.MineList() or {}
	MenuUtil.CreateContextMenu(self, function(owner, root)
		root:CreateTitle("Suggested (comes with VoidSequencer, updated by us)")
		if #choices > 0 then
			root:CreateRadio("Automatic (matches your hero tree)", function() return not mineName and pick == nil end,
				function() VS.SetRotationPick(nil) end)
			for _, c in ipairs(choices) do
				root:CreateRadio(c.label, function() return not mineName and pick == c.key end, function() VS.SetRotationPick(c.key) end)
			end
		else
			menuTip(root:CreateRadio(VS.SuggestedLabel and VS.SuggestedLabel() or "Suggested",
				function() return not mineName end, function() VS.UseMine(nil) end),
				"Suggested rotation", "The rotation that comes with VoidSequencer for your class. Updates can improve it.")
		end
		root:CreateDivider()
		root:CreateTitle("Your own (never changed by updates)")
		if #list == 0 then
			root:CreateButton("|cff888888none yet: make one below, or just edit the steps|r", function() end)
		end
		for _, r in ipairs(list) do
			root:CreateRadio(r.name, function() return mineName == r.name end, function() VS.UseMine(r.name) end)
		end
		root:CreateDivider()
		menuTip(root:CreateButton("New: copy of what runs now...", function()
			pendingName = { action = "new", default = mineName and (mineName .. " copy") or (VS.MineDefaultName and VS.MineDefaultName()) or "My rotation" }
			StaticPopup_Show("VOIDSEQ_NAME", "Name your new rotation:")
		end), "New rotation, copied", "Starts from exactly what key 1 does now, so you only change what you want.")
		menuTip(root:CreateButton("New: start empty...", function()
			pendingName = { action = "blank", default = "My rotation" }
			StaticPopup_Show("VOIDSEQ_NAME", "Name your new, empty rotation:")
		end), "New rotation, empty", "Starts with one empty step: pick every spell yourself.")
		if mineName then
			root:CreateButton("Rename \"" .. mineName .. "\"...", function()
				pendingName = { action = "rename", old = mineName, default = mineName }
				StaticPopup_Show("VOIDSEQ_NAME", "New name:")
			end)
			root:CreateButton("|cffff5555Delete \"" .. mineName .. "\"...|r", function()
				pendingName = { action = "delete", old = mineName }
				StaticPopup_Show("VOIDSEQ_DELETE", mineName)
			end)
		end
		root:CreateDivider()
		menuTip(root:CreateButton("Share: export as text...", function()
			ShowTextDialog({
				title = "Share your rotation",
				help = "Select all (Ctrl+A), copy (Ctrl+C) and paste it anywhere (Discord, a friend). They import it with Rotation > Import.",
				text = VS.ExportMine(mineName), readOnly = true,
			})
		end), "Export", "Turns the rotation that runs now into text you can copy and share.")
		menuTip(root:CreateButton("Import: paste a shared rotation...", function()
			ShowTextDialog({
				title = "Import a rotation",
				help = "Paste the text someone shared (Ctrl+V), then Import. It's added to your own rotations and switched on.",
				text = "", okText = "Import",
				onAccept = function(text)
					local r, msg = VS.ImportMine(text)
					if not r then print("|cffff5555VoidSequencer|r: " .. tostring(msg)) return false end
					return true
				end,
			})
		end), "Import", "Paste a rotation another player shared. Nothing you have is replaced.")
	end)
end)
tip(rotButton, "Rotation",
	"Which rotation key 1 runs. Suggested ones come with VoidSequencer and get better with updates.",
	"Your own: the moment you change a step, VoidSequencer makes your own copy and runs it. Updates never touch yours, and you can switch back to the suggested one any time.",
	"Make, rename, delete, share and import rotations here.")

local function RefreshRotationButton()
	local mineName = VS.MineActive and VS.MineActive()
	if mineName then
		rotButton:SetText("Yours: " .. mineName)
	else
		local choices = VS.RotationChoices and VS.RotationChoices() or {}
		local cur = VS.CurrentSpec and VS.CurrentSpec()
		local text = VS.SuggestedLabel and VS.SuggestedLabel() or "(no rotation for this spec yet)"
		for _, c in ipairs(choices) do
			if c.key == cur then text = c.label end
		end
		if not (VS.GetRotationPick and VS.GetRotationPick()) and #choices > 0 then text = "Auto: " .. text end
		rotButton:SetText("Suggested: " .. text)
	end
	rotButton:SetEnabled(true)
end

local checkLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
checkLabel:SetPoint("TOPLEFT", rotLabel, "BOTTOMLEFT", 0, -14)
checkLabel:SetText("Rotation check:")

local checkText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
checkText:SetPoint("LEFT", checkLabel, "RIGHT", 10, 0)
checkText:SetWidth(220); checkText:SetJustifyH("LEFT"); checkText:SetWordWrap(false)

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

local testButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
testButton:SetSize(120, 22)
testButton:SetPoint("LEFT", checkButton, "RIGHT", 6, 0)
testButton:SetText("Test my rotation")
testButton:SetScript("OnClick", function() if VS.OpenRotationTest then VS.OpenRotationTest() end end)
testButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Test my rotation")
	GameTooltip:AddLine("Hit a training dummy for 2-3 minutes and see each spell's casts per minute next to the top players' for your spec. Copy the report into our Discord to help tune it (/vstest).", 1, 1, 1, true)
	GameTooltip:Show()
end)
testButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function RefreshCheck()
	checkText:SetText(VS.RotationSummary and VS.RotationSummary() or "")
end

local modLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
modLabel:SetPoint("TOPLEFT", checkLabel, "BOTTOMLEFT", 0, -12)
modLabel:SetText("Hold a key while you press your rotation key to cast instead:")

local modRows = {}
local function refreshModRows()
	for _, m in ipairs(modRows) do
		local cur = (VS.GetMod and VS.GetMod(m.key)) or ""
		m.btn:SetText(cur ~= "" and cur or "|cff888888(none)|r")
	end
end

local modAnchor, modPrev = modLabel, nil
for _, def in ipairs({
	{ key = "alt",   text = "Hold ALT", short = "Alt" },
	{ key = "ctrl",  text = "Hold CTRL", short = "Ctrl" },
	{ key = "shift", text = "Hold SHIFT", short = "Shift" },
}) do
	local mk = def.key
	local row = CreateFrame("Frame", nil, panel)
	row:SetSize(200, 24)
	-- the three side by side on one row (room for the step list below)
	if modPrev then row:SetPoint("LEFT", modPrev, "RIGHT", 8, 0) else row:SetPoint("TOPLEFT", modLabel, "BOTTOMLEFT", 0, -6) end

	local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(40); lbl:SetJustifyH("LEFT")
	lbl:SetText(def.short)

	local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	btn:SetSize(150, 22); btn:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
	local bfs = btn:GetFontString()
	if bfs then bfs:SetFontObject("GameFontHighlightSmall"); bfs:SetWordWrap(false); bfs:SetWidth(140) end
	btn:SetScript("OnClick", function(self)
		MenuUtil.CreateContextMenu(self, function(owner, root)
			root:CreateTitle("Pick an ability for " .. def.text)
			root:CreateButton("|cff888888(none)|r", function() VS.SetMod(mk, ""); refreshModRows() end)
			root:CreateDivider()
			local groups = VS.SpellGroups and VS.SpellGroups() or {}
			for _, g in ipairs(groups) do
				local sub = root:CreateButton(g.label)
				for _, name in ipairs(g.list) do sub:CreateButton(name, function() VS.SetMod(mk, name); refreshModRows() end) end
			end
			if #groups == 0 then
				for _, name in ipairs(VS.SpellPool()) do
					root:CreateButton(name, function() VS.SetMod(mk, name); refreshModRows() end)
				end
			end
			root:CreateDivider()
			root:CreateButton("Type an ability name...", function()
				pendingModMod = mk
				StaticPopup_Show("VOIDSEQ_MODCUSTOM")
			end)
		end)
	end)

	tip(btn, def.text, "Hold this key while you press your rotation key and this ability is cast instead of the step (a defensive, a big cooldown...).", "Part of your rotation: shared and imported with it.")
	modRows[#modRows + 1] = { key = mk, btn = btn }
	if not modPrev then modAnchor = row end
	modPrev = row
end

-- Header refresh: dynamic subtitle (current spec) + modifier picker labels.
local function RefreshHeader()
	local spec = (VS.CurrentSpec and VS.CurrentSpec()) or ""
	if spec ~= "" and VS.SpecLabel then spec = VS.SpecLabel(spec) end
	sub:SetText("One-button rotation sequencer" .. (spec ~= "" and (" - " .. spec) or "")
		.. ". Spam your key; the ST/AoE switch picks the rotation.")
	refreshModRows()
end

-- ---------------------------------------------------------------------------
-- Rotation editor: ST / AoE tabs
-- ---------------------------------------------------------------------------
local edLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
edLabel:SetPoint("TOPLEFT", modAnchor, "BOTTOMLEFT", 0, -14)
edLabel:SetText("Rotation editor: each press runs the next step, top to bottom, then starts over")

-- which rotation you're editing, and what an edit does (yours, or a copy of the suggested one)
local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", edLabel, "BOTTOMLEFT", 0, -4)
status:SetWidth(560); status:SetJustifyH("LEFT")

local tabST = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
tabST:SetSize(110, 22)
tabST:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -6)
tabST:SetText("Single Target")
tip(tabST, "Single Target", "The steps for one enemy (bosses). The ST / AoE switch on screen picks which list key 1 runs.")

local tabAOE = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
tabAOE:SetSize(110, 22)
tabAOE:SetPoint("LEFT", tabST, "RIGHT", 6, 0)
tabAOE:SetText("AoE")
tip(tabAOE, "AoE", "The steps for several enemies (packs). The ST / AoE switch on screen picks which list key 1 runs.")

local defBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
defBtn:SetSize(150, 22)
defBtn:SetPoint("LEFT", tabAOE, "RIGHT", 24, 0)
defBtn:SetText("Restore suggested steps")
tip(defBtn, "Restore suggested steps", "Puts the suggested rotation's steps back into this list (Single Target or AoE) of YOUR rotation. Your other list, every-press lines and modifier casts stay as they are.")

local headBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
headBtn:SetSize(110, 22)
headBtn:SetPoint("LEFT", defBtn, "RIGHT", 6, 0)
headBtn:SetText("Every press...")
tip(headBtn, "Every press",
	"Macro lines that run on EVERY press, before the step: e.g. /startattack (auto attack), /petattack (send your pet), /cast !Auto Shot.",
	"Leave it empty and only the steps run.")

local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", tabST, "BOTTOMLEFT", 0, -4)
hint:SetWidth(560)
hint:SetJustifyH("LEFT")
hint:SetText("A step casts the first of its spells that's ready; the others are fallbacks. Spells you haven't learned are skipped. Click a spell to change it.")

local function RefreshStatus()
	local mineName = VS.MineActive and VS.MineActive()
	if mineName then
		status:SetText("|cff55ff55Editing your own rotation \"" .. mineName .. "\".|r Updates never change it. Switch, share or rename it under Rotation above.")
	else
		status:SetText("|cffffd200Showing the suggested rotation.|r Change anything and VoidSequencer makes it your own copy; the suggested one stays as it ships.")
	end
	defBtn:SetEnabled(mineName ~= nil)
end

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
tip(addStepBtn, "Add a step", "Adds an empty step at the bottom. Click its (pick) button to choose a spell.")

local scroll = CreateFrame("ScrollFrame", "VoidSeqEditScroll", panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
scroll:SetPoint("BOTTOMLEFT", addStepBtn, "TOPLEFT", 0, 12)
scroll:SetWidth(560)
local content = CreateFrame("Frame", nil, scroll)
content:SetSize(536, 10)
scroll:SetScrollChild(content)

local rows = {}  -- pooled step-row frames

-- Open the spell-picker menu for a tile (one spell slot in a step), or for + Spell (slotIdx nil: the pick is added
-- at the end of the step; nothing changes until a spell is picked).
local function openSpellMenu(anchor, stepIdx, slotIdx)
	MenuUtil.CreateContextMenu(anchor, function(owner, root)
		local function pick(value) VS.SetSpell(editMode, stepIdx, slotIdx, value); VS.Apply(); RefreshList() end
		root:CreateTitle("Pick a spell (your spellbook)")
		local groups = VS.SpellGroups and VS.SpellGroups() or {}
		for _, g in ipairs(groups) do
			local sub = root:CreateButton(g.label)
			for _, name in ipairs(g.list) do sub:CreateButton(name, function() pick(name) end) end
		end
		if #groups == 0 then   -- the spellbook isn't readable here: the old list (action bars + the rotation's)
			for _, name in ipairs(VS.SpellPool()) do root:CreateButton(name, function() pick(name) end) end
		end
		local items = VS.ItemChoices and VS.ItemChoices() or {}
		if #items > 0 then
			local sub = root:CreateButton("Items (trinkets, potions...)")
			menuTip(sub, "Items", "Use an item in this step: a trinket you wear or something in your bags with a Use: effect.")
			for _, it in ipairs(items) do sub:CreateButton(it.text, function() pick(it.value) end) end
		end
		root:CreateDivider()
		menuTip(root:CreateButton("Type a spell name...", function()
			pendingCustom = { step = stepIdx, slot = slotIdx }
			StaticPopup_Show("VOIDSEQ_CUSTOM")
		end), "Type a spell name", "For a spell that isn't listed (exact name as in your spellbook).")
		menuTip(root:CreateButton("Type a macro line...", function()
			pendingCustom = { step = stepIdx, slot = slotIdx }
			StaticPopup_Show("VOIDSEQ_MACROLINE")
		end), "Type a macro line", "Anything a macro can do, as one line starting with /: e.g. /cast [mod:shift] Feign Death, /castsequence reset=target Hunter's Mark, null, /use 13.")
		if slotIdx and #VS.Seq(editMode)[stepIdx] > 1 then
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
		t:SetScript("OnClick", function(self) openSpellMenu(self, self.row.index, self.slot) end)
		t:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			local v = VS.Seq(editMode)[self.row.index]
			v = v and v[self.slot] or ""
			GameTooltip:AddLine(v ~= "" and v or "Empty slot")
			GameTooltip:AddLine("Click to pick a spell, an item or a macro line, or to remove it.", 1, 1, 1, true)
			GameTooltip:AddLine("In a step the first one that's ready is cast; the ones after it are fallbacks.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		t:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
	r.add:SetScript("OnClick", function(self) openSpellMenu(self, r.index, nil) end)
	tip(r.up, "Move up", "Moves this step one place earlier.")
	tip(r.dn, "Move down", "Moves this step one place later.")
	tip(r.del, "Delete step", "Removes this step (a rotation keeps at least one).")
	tip(r.add, "Add a fallback", "Pick a spell to add to this step: it's cast when the ones before it aren't ready.")

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
	RefreshStatus()
	tabVisual()
	RefreshList()
end

tabST:SetScript("OnClick", function() editMode = "ST"; RefreshAll() end)
tabAOE:SetScript("OnClick", function() editMode = "AOE"; RefreshAll() end)
defBtn:SetScript("OnClick", function()
	if VS.Defaults then VS.Defaults(editMode); RefreshList() end
end)
headBtn:SetScript("OnClick", function()
	ShowTextDialog({
		title = "Every press",
		help = "One macro line per row; they run on every press, before the step. Examples: /startattack   /petattack [@target,harm,nodead]   /cast [@target,harm] !Auto Shot",
		text = VS.GetHead and VS.GetHead() or "", okText = "Save",
		onAccept = function(text) VS.SetHead(text); if RefreshAll then RefreshAll() end return true end,
	})
end)

-- ---------------------------------------------------------------------------
-- A small window for longer text: the every-press lines, sharing (export) and importing
-- ---------------------------------------------------------------------------
do
	local f
	ShowTextDialog = function(o)
		if not f then
			f = CreateFrame("Frame", "VoidSeqTextDialog", UIParent, "BackdropTemplate")
			f:SetSize(520, 300); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG"); f:SetToplevel(true)
			f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
			f:SetBackdropColor(0.05, 0.05, 0.08, 0.97); f:SetBackdropBorderColor(0.6, 0.4, 0.9, 1)
			f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
			f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
			f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge"); f.title:SetPoint("TOPLEFT", 14, -12)
			f.help = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			f.help:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6); f.help:SetWidth(490); f.help:SetJustifyH("LEFT")
			local sc = CreateFrame("ScrollFrame", "VoidSeqTextDialogScroll", f, "UIPanelScrollFrameTemplate")
			sc:SetPoint("TOPLEFT", f.help, "BOTTOMLEFT", 0, -8); sc:SetPoint("BOTTOMRIGHT", -32, 44)
			local eb = CreateFrame("EditBox", nil, sc)
			eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject("ChatFontNormal"); eb:SetWidth(460)
			eb:SetScript("OnEscapePressed", function() f:Hide() end)
			eb:SetScript("OnTextChanged", function(self, user)
				if user and f.readOnly then self:SetText(f.orig or ""); self:HighlightText() end
			end)
			sc:SetScrollChild(eb); f.eb = eb
			local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
			bg:SetPoint("TOPLEFT", sc, -4, 4); bg:SetPoint("BOTTOMRIGHT", sc, 4, -4); bg:SetColorTexture(0, 0, 0, 0.5)
			sc:EnableMouse(true); sc:SetScript("OnMouseDown", function() eb:SetFocus() end)
			f.ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.ok:SetSize(100, 22); f.ok:SetPoint("BOTTOMRIGHT", -120, 12)
			f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.cancel:SetSize(100, 22); f.cancel:SetPoint("BOTTOMRIGHT", -14, 12)
			f.cancel:SetScript("OnClick", function() f:Hide() end)
			f.ok:SetScript("OnClick", function()
				if f.onAccept then
					local keep = f.onAccept(f.eb:GetText() or "")
					if keep == false then return end   -- something to fix: the window stays open
				end
				f:Hide()
			end)
			tinsert(UISpecialFrames, "VoidSeqTextDialog")
		end
		f.title:SetText(o.title or "")
		f.help:SetText(o.help or "")
		f.readOnly, f.orig, f.onAccept = o.readOnly, o.text or "", o.onAccept
		f.eb:SetText(o.text or "")
		f.ok:SetShown(not o.readOnly)
		f.ok:SetText(o.okText or OKAY)
		f.cancel:SetText(o.readOnly and CLOSE or CANCEL)
		f:Show()
		f.eb:SetFocus()
		if o.readOnly then f.eb:HighlightText() end
	end
end

-- Enter in a popup's box = its first button. The modern client keeps that button in a container
-- (dialog:GetButton1()); older ones have dialog.button1.
local function popupEnter(self)
	local d = self:GetParent()
	local b = (d.GetButton1 and d:GetButton1()) or d.button1
	if b then b:Click() end
end

-- Name a rotation (new / new empty / rename), delete one
StaticPopupDialogs["VOIDSEQ_NAME"] = {
	text = "%s",
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true, maxLetters = 40, editBoxWidth = 260,
	OnShow = function(self)
		local box = self.editBox or self:GetEditBox()
		box:SetText(pendingName and pendingName.default or ""); box:HighlightText()
	end,
	OnAccept = function(self)
		local box = self.editBox or self:GetEditBox()
		local txt = box:GetText() or ""
		local p = pendingName
		pendingName = nil
		if not p then return end
		if p.action == "new" then VS.NewMine(txt, false)
		elseif p.action == "blank" then VS.NewMine(txt, true)
		elseif p.action == "rename" then VS.RenameMine(p.old, txt) end
	end,
	EditBoxOnEnterPressed = popupEnter,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}
StaticPopupDialogs["VOIDSEQ_DELETE"] = {
	text = "Delete your rotation \"%s\"? This can't be undone (Rotation > Share keeps a copy as text).",
	button1 = DELETE, button2 = CANCEL,
	OnAccept = function()
		local p = pendingName
		pendingName = nil
		if p and p.action == "delete" then VS.DeleteMine(p.old) end
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
}
-- One macro line in a step: kept as typed (brackets and all); a leading / is added when it's missing
StaticPopupDialogs["VOIDSEQ_MACROLINE"] = {
	text = "Type one macro line (starts with /):\ne.g.  /cast [mod:shift] Feign Death",
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true, maxLetters = 255,
	OnAccept = function(self)
		local box = self.editBox or self:GetEditBox()
		local txt = (box:GetText() or ""):gsub("[\r\n]", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if txt ~= "" and pendingCustom then
			if txt:sub(1, 1) ~= "/" then txt = "/" .. txt end
			VS.SetSpell(editMode, pendingCustom.step, pendingCustom.slot, txt)
			VS.Apply(); RefreshList()
		end
		pendingCustom = nil
	end,
	EditBoxOnEnterPressed = popupEnter,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

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
	EditBoxOnEnterPressed = popupEnter,
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
	EditBoxOnEnterPressed = popupEnter,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

-- ---------------------------------------------------------------------------
-- Keybind display refresh (kept from the old panel) + show hook
-- ---------------------------------------------------------------------------
local function RefreshOptions()
	local k = VS.GetKey and VS.GetKey()
	-- the game's own name for it ("Mouse Wheel Up", "Shift-1"), not the raw binding key
	local shown = k and ((GetBindingText and GetBindingText(k)) or k)
	kbCurrent:SetText(shown and ("|cff55ff55" .. shown .. "|r") or "|cffff5555unbound|r")
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

-- The settings window is protected in combat (ADDON_ACTION_BLOCKED on OpenSettingsPanel,
-- a minimap click mid-fight in Warsong Gulch, 2026-11-04): open it when combat ends.
local openAfterCombat = CreateFrame("Frame")
openAfterCombat:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	VS.OpenOptions()
end)
function VS.OpenOptions()
	if InCombatLockdown() then
		openAfterCombat:RegisterEvent("PLAYER_REGEN_ENABLED")
		print("|cff9966ffVoidSequencer|r: settings open when combat ends.")
		return
	end
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

-- Read-only hooks for the all-in-one VoidHub window (2026-11-24): the hub's Sequencer page edits the same rotation
-- through these same VS.* functions (Seq, SetSpell, AddStep, MoveStep, SetMod, SetRotationPick, CaptureKey...),
-- and follows VS.RefreshOptions. Nothing here changes this panel.
_G.VoidSequencerHub = VS
