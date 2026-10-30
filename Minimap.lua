----------------------------------------------------------------------
-- VoidSequencer Minimap — standardized minimap button.
-- Global name VoidSequencerMinimapBtn so VoidHubBundle discovers it.
--   Left-click  -> open options
--   Right-click -> show/hide the on-screen ST/AoE switch
--   Drag        -> reposition around the minimap (angle in CharDB)
----------------------------------------------------------------------
local ADDON, VS = ...

local btn

local function PositionButton(b)
	VoidSequencerCharDB = VoidSequencerCharDB or {}
	local angle = math.rad(VoidSequencerCharDB.minimapAngle or 215)
	local radius = (Minimap:GetWidth() / 2) + 6
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function CreateMinimapButton()
	if btn then return btn end
	if _G.VoidSequencerMinimapBtn then btn = _G.VoidSequencerMinimapBtn; return btn end
	if not Minimap then return end

	btn = CreateFrame("Button", "VoidSequencerMinimapBtn", Minimap)
	btn:SetSize(28, 28)
	btn:SetFrameStrata("MEDIUM")
	btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

	local icon = btn:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER")
	icon:SetTexture("Interface\\Icons\\Spell_Shadow_DeathCoil")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = btn:CreateTexture(nil, "OVERLAY")
	border:SetSize(54, 54)
	border:SetPoint("TOPLEFT", -2, 2)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	btn:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			-- the switch's visibility is a state driver (VS.ApplyEnabled): flip the setting
			if VoidSequencerDB and VS.ApplyEnabled and not InCombatLockdown() then
				VoidSequencerDB.switchHidden = not VoidSequencerDB.switchHidden
				VS.ApplyEnabled()
			end
		else
			if VS.OpenOptions then VS.OpenOptions() end
		end
	end)

	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("|cffcc66ffVoidSequencer|r", 1, 1, 1)
		GameTooltip:AddLine("Left-click: options", 0.85, 0.85, 0.85)
		GameTooltip:AddLine("Right-click: show/hide ST-AoE switch", 0.85, 0.85, 0.85)
		GameTooltip:AddLine("Drag: reposition around minimap", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	btn:SetMovable(true)
	btn:RegisterForDrag("LeftButton")
	btn:SetScript("OnDragStart", function(self) self._dragging = true end)
	btn:SetScript("OnDragStop", function(self) self._dragging = false end)
	btn:SetScript("OnUpdate", function(self)
		if self._dragging then
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local px, py = GetCursorPosition()
			if not mx or not px or not scale then return end
			px = px / scale; py = py / scale
			VoidSequencerCharDB = VoidSequencerCharDB or {}
			VoidSequencerCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
			PositionButton(self)
		end
	end)

	PositionButton(btn)
	return btn
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	CreateMinimapButton()
	-- a saved "switch hidden" preference is applied by VS.ApplyEnabled at login
end)
