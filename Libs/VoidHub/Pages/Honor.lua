----------------------------------------------------------------------
-- VoidHub page: VoidHonor (WoW Forever PvP). Data: VoidHonorHub (VoidHonor/Core.lua).
--   Planner        rank, this week's Rank Points vs the cap, room left in weeklies and wins, Honor, the Field of
--                  Honor weeks, the PvP reputations, and one line on what to do next
--   Did it count   every change to Rank Points / Honor / PvP reputation, with its cause, and why a zero was a zero
--   Battlegrounds  every match: map, result, Rank Points, Honor, kills; your averages per map
--   World PvP      your honorable kills outside battlegrounds (today, this week, by zone), a weekly that asks for kills,
--                  and VoidBounty's "danger here" line (VoidBounty moved into VoidHonor 11-27)
--   Blood debts, Sightings, Most wanted   VoidBounty's lists (Pages/PvP.lua's builders); Settings adds its settings
--   Settings       the chat lines
----------------------------------------------------------------------
local ns = _G.VoidHubWin
if not ns or ns.skip then return end   -- another Void addon's copy of VoidHub runs the window
local K = ns.Kit

local function HH() return _G.VoidHonorHub end
local GOLD, GREEN, RED, CYAN = "|cffffd27a", "|cff55ff55", "|cffff6655", "|cff00c7ff"

local function card(parent, w, h)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(w, h)
    K.Box(c, { 0.08, 0.09, 0.12, 0.9 }, K.EDGE)
    c.title = K.Text(c, "GameFontDisableSmall"); c.title:SetPoint("TOPLEFT", 10, -8)
    c.big = K.Text(c, "GameFontHighlightLarge"); c.big:SetPoint("TOPLEFT", 10, -24)
    c.sub = K.Text(c, "GameFontHighlightSmall"); c.sub:SetPoint("TOPLEFT", 10, -48); c.sub:SetWidth(w - 20); c.sub:SetJustifyH("LEFT")
    return c
end

local function tipOn(f, fn)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); fn(GameTooltip); GameTooltip:Show() end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

----------------------------------------------------------------------
-- Planner
----------------------------------------------------------------------
local WEEK_COLORS = {
    done = { 0.20, 0.55, 0.25, 0.55 }, log = { 0.75, 0.60, 0.15, 0.55 }, open = { 0, 0.55, 0.75, 0.45 }, locked = { 0.2, 0.2, 0.25, 0.5 },
}
local WEEK_TEXT = { done = "done", log = "in your log", open = "open", locked = "later" }

local function PlanBuild(host)
    local P = CreateFrame("Frame", nil, host)
    P:SetAllPoints()
    P.rank = K.Text(P, "GameFontNormalLarge"); P.rank:SetPoint("TOPLEFT", 16, -12)
    P.season = K.Text(P, "GameFontHighlightSmall"); P.season:SetPoint("TOPRIGHT", -16, -16); P.season:SetJustifyH("RIGHT")

    P.barLabel = K.Text(P, "GameFontHighlightSmall"); P.barLabel:SetPoint("TOPLEFT", 16, -40)
    P.bar = K.Bar(P, 300, 18); P.bar:SetPoint("TOPLEFT", 16, -56); P.bar:SetPoint("RIGHT", P, "RIGHT", -16, 0)
    P.rankLine = K.Text(P, "GameFontHighlightSmall"); P.rankLine:SetPoint("TOPLEFT", 16, -80); P.rankLine:SetPoint("RIGHT", -16, 0); P.rankLine:SetJustifyH("LEFT")

    P.cards = {}
    for i = 1, 3 do
        local c = card(P, 262, 74)
        if i == 1 then c:SetPoint("TOPLEFT", 16, -102) else c:SetPoint("TOPLEFT", P.cards[i - 1], "TOPRIGHT", 10, 0) end
        P.cards[i] = c
    end
    P.cards[2].bar = K.Bar(P.cards[2], 242, 6); P.cards[2].bar:SetPoint("TOPLEFT", 10, -46); P.cards[2].bar.text:Hide()

    P.fohHead = K.Text(P, "GameFontNormal", CYAN .. "Field of Honor|r  " .. K.GREY .. "weekly, Wizzik Dustfizz in Gadgetzan (level 60)|r")
    P.fohHead:SetPoint("TOPLEFT", 16, -188)
    P.weeks = {}
    for i = 1, 8 do
        local w = CreateFrame("Frame", nil, P)
        w:SetSize(84, 40)
        if i == 1 then w:SetPoint("TOPLEFT", 16, -206) else w:SetPoint("TOPLEFT", P.weeks[i - 1], "TOPRIGHT", 6, 0) end
        w.bg = w:CreateTexture(nil, "BACKGROUND"); w.bg:SetAllPoints()
        w.a = K.Text(w, "GameFontHighlightSmall"); w.a:SetPoint("TOP", 0, -6)
        w.b = K.Text(w, "GameFontHighlightSmall"); w.b:SetPoint("BOTTOM", 0, 6)
        tipOn(w, function(t)
            local q = w.q
            if not q then return end
            t:AddLine(q.title, 1, 1, 1)
            t:AddLine(q.state == "done" and "Turned in." or q.state == "log" and "In your quest log: hand it in to Wizzik Dustfizz, Gadgetzan."
                or q.state == "open" and "Open: an earlier week can still be done now." or "A later week: opens with its week.", 0.8, 0.8, 0.8, true)
            if q.obj then t:AddLine(q.obj, 1, 0.82, 0, true) end
            t:AddLine(("Week 1 gave +%d Rank Points and +%d Honor (measured)."):format(HH().GUIDE.foh, HH().GUIDE.fohHonor), 0.6, 0.6, 0.6, true)
        end)
        P.weeks[i] = w
    end

    P.repHead = K.Text(P, "GameFontNormal", CYAN .. "Reputations|r"); P.repHead:SetPoint("TOPLEFT", 16, -258)
    P.reps = {}
    for i = 1, 4 do
        local r = CreateFrame("Frame", nil, P)
        r:SetSize(360, 18)
        r:SetPoint("TOPLEFT", 16, -276 - (i - 1) * 20)
        r.a = K.Text(r, "GameFontHighlightSmall"); r.a:SetPoint("LEFT"); r.a:SetWidth(200); r.a:SetJustifyH("LEFT"); r.a:SetWordWrap(false)
        r.bar = K.Bar(r, 150, 12); r.bar:SetPoint("LEFT", 205, 0); r.bar.text:SetFontObject("GameFontHighlightSmall")
        P.reps[i] = r
    end

    P.recentHead = K.Text(P, "GameFontNormal", CYAN .. "Recently|r"); P.recentHead:SetPoint("TOPLEFT", 400, -258)
    P.recent = {}
    for i = 1, 4 do
        local t = K.Text(P, "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", 400, -278 - (i - 1) * 20); t:SetPoint("RIGHT", -16, 0)
        t:SetJustifyH("LEFT"); t:SetWordWrap(false)
        P.recent[i] = t
    end

    P.nextBox = CreateFrame("Frame", nil, P)
    P.nextBox:SetPoint("TOPLEFT", 16, -364); P.nextBox:SetPoint("RIGHT", -16, 0); P.nextBox:SetHeight(34)
    K.Box(P.nextBox, { K.A[1], K.A[2], K.A[3], 0.10 }, { K.A[1], K.A[2], K.A[3], 0.45 })
    P.next = K.Text(P.nextBox, "GameFontHighlight"); P.next:SetPoint("LEFT", 10, 0); P.next:SetPoint("RIGHT", -10, 0); P.next:SetJustifyH("LEFT")

    P.empty = K.Text(P, "GameFontHighlight"); P.empty:SetPoint("TOPLEFT", 16, -40); P.empty:SetWidth(700); P.empty:SetJustifyH("LEFT")

    local function render()
        if not P:IsVisible() then return end
        local H = HH()
        local p = H and H.Plan()
        local any = p ~= nil
        for _, f in ipairs({ P.barLabel, P.bar, P.rankLine, P.fohHead, P.repHead, P.recentHead, P.nextBox, P.season }) do f:SetShown(any) end
        for _, c in ipairs(P.cards) do c:SetShown(any) end
        for _, r in ipairs(P.reps) do r:SetShown(any) end
        for _, t in ipairs(P.recent) do t:SetShown(any) end
        P.empty:SetShown(not any)
        if not any then
            P.rank:SetText(CYAN .. "PvP rank|r")
            P.empty:SetText("The game hasn't given the PvP rank yet (it comes a moment after logging in).\n\n"
                .. K.GREY .. "WoW Forever keeps the rank as \"PvP Rank Points\". Open this page again in a few seconds.|r")
            for _, w in ipairs(P.weeks) do w:Hide() end
            return
        end
        local r, N = p.rank, H.Num
        P.rank:SetText(("%sRank %d|r  %s"):format(CYAN, r.rank, r.name))
        P.season:SetText(("Week %s%s"):format(r.week or "?", p.resetIn and ("  ·  cap rises in " .. H.Duration(p.resetIn)) or ""))
        P.barLabel:SetText(("This week: %s%s|r of %s Rank Points %s(this week's cap, rank %s)|r"):format(GOLD, N(r.rp), N(r.cap or 0), K.GREY, tostring(r.weekRank or "?")))
        P.bar:Fill(r.rp, r.cap or r.rp)
        P.bar.text:SetText(("%s / %s"):format(N(r.rp), N(r.cap or 0)))
        local bits = {}
        if r.nextAt then bits[#bits + 1] = ("Next rank: %s at %s (%s to go)"):format(r.nextName, N(r.nextAt), N(math.max(0, r.nextAt - r.rp))) end
        local rl, rw = H.NextReward(r.rank)
        if rl then bits[#bits + 1] = ("Rank %d reward: %s"):format(rl, rw) end
        if r.maxRP then bits[#bits + 1] = ("Rank %d needs %s"):format(r.maxRank, N(r.maxRP)) end
        P.rankLine:SetText(K.GREY .. table.concat(bits, "   ·   ") .. "|r")

        -- cards
        local c1, c2, c3 = P.cards[1], P.cards[2], P.cards[3]
        c1.title:SetText("ROOM THIS WEEK")
        c1.big:SetText(r.atCap and (GREEN .. "at the cap|r") or (GOLD .. N(r.room or 0) .. "|r Rank Points"))
        if r.atCap then c1.sub:SetText("more won't count until the cap rises")
        else
            local w = math.min(p.openWeeklies, math.ceil((r.room or 0) / H.GUIDE.foh))
            c1.sub:SetText(("about %d weekl%s + %s wins%s"):format(w, w == 1 and "y" or "ies", p.winsNeeded and tostring(p.winsNeeded) or "?",
                p.winMeasured and "" or K.GREY .. " (guide)|r"))
        end
        tipOn(c1, function(t)
            t:AddLine("Room this week", 1, 1, 1)
            t:AddLine("Rank Points count up to this week's cap. The cap rises every week until rank 14.", 0.8, 0.8, 0.8, true)
            t:AddLine(p.winMeasured and ("A win gives you %s Rank Points on average (%d wins logged)."):format(N(p.winRP), p.wins)
                or ("A win: about %d Rank Points (a guide number). VoidHonor measures your own from your next wins."):format(H.GUIDE.win), 0.8, 0.8, 0.8, true)
        end)
        local h = p.honor
        c2.title:SetText("HONOR")
        c2.big:SetText((h and h.atMax and RED or "|cffffffff") .. N(h and h.have or 0) .. "|r " .. K.GREY .. "/ " .. N(h and h.max or 25000) .. "|r")
        c2.sub:SetText(h and h.atMax and "at the cap: spend some" or "buys PvP gear; doesn't raise your rank")
        c2.sub:SetPoint("TOPLEFT", 10, -58)
        c2.bar:Fill(h and h.have or 0, h and h.max or 25000)
        c3.title:SetText("CAP RISE THIS WEEK")
        c3.big:SetText(r.rise and ("+" .. N(r.rise)) or "?")
        c3.sub:SetText(("lets you reach rank %s this week"):format(tostring(r.weekRank or "?")))

        -- Field of Honor
        for i, w in ipairs(P.weeks) do
            local q = p.weeklies[i]
            w.q = q
            if q then
                local col = WEEK_COLORS[q.state]
                w.bg:SetColorTexture(col[1], col[2], col[3], col[4])
                w.a:SetText("Week " .. q.week)
                w.b:SetText((q.state == "done" and GREEN or q.state == "log" and GOLD or q.state == "open" and CYAN or K.GREY) .. WEEK_TEXT[q.state] .. "|r")
                w:Show()
            else
                w:Hide()
            end
        end

        -- reputations
        for i, row in ipairs(P.reps) do
            local e = H.Reps()[i]
            if e then
                row.a:SetText(("%s %s(%s)|r"):format(e.name, K.GREY, e.where))
                if e.standing then
                    local span = math.max(1, (e.hi or 0) - (e.lo or 0))
                    row.bar:Fill(math.max(0, e.standing - (e.lo or 0)), span)
                    row.bar.text:SetText(e.label or "")
                else
                    row.bar:Fill(0, 1); row.bar.text:SetText(K.GREY .. "not met|r")
                end
            end
        end

        -- recently
        local log = H.Log()
        for i, t in ipairs(P.recent) do
            local e = log[i]
            if e then
                local amt = (e.rp and e.rp ~= 0) and (GOLD .. ("%+d RP|r"):format(e.rp)) or (e.kind == "zero" and (RED .. "0 RP|r") or "")
                if e.honor and e.honor ~= 0 then amt = amt .. (" %+d Honor"):format(e.honor) end
                t:SetText(("%s%s|r  %s  %s"):format(K.GREY, date("%a %H:%M", e.at), e.what or "", amt))
            else
                t:SetText(i == 1 and (K.GREY .. "nothing yet: a turn-in or a battleground shows up here|r") or "")
            end
        end

        P.next:SetText(GOLD .. "Next:|r " .. (p.next or "nothing open for Rank Points this week."))
    end
    P:SetScript("OnShow", render)
    -- the quest log (a weekly taken or dropped), and VoidHonor's own signal after every read it logs
    K.LiveEvents(P, { "QUEST_ACCEPTED", "QUEST_REMOVED" }, render, 1)
    local H0 = HH()
    if H0 and H0.OnChange then H0.OnChange(function() render() end) end
    P.render = render
    return P
end

----------------------------------------------------------------------
-- Did it count / Battlegrounds: lists
----------------------------------------------------------------------
local function ListPanel(host, headFn, itemsFn)
    local P = CreateFrame("Frame", nil, host)
    P:SetAllPoints()
    P.head = K.Text(P, "GameFontHighlight"); P.head:SetPoint("TOPLEFT", 16, -12); P.head:SetPoint("RIGHT", -16, 0)
    P.head:SetJustifyH("LEFT"); P.head:SetSpacing(3)
    P.list = K.List(P, 22, function(r)
        r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
        r.t = K.Text(r, "GameFontDisableSmall"); r.t:SetPoint("LEFT", 6, 0); r.t:SetWidth(78); r.t:SetJustifyH("LEFT")
        r.a = K.Text(r, "GameFontHighlight"); r.a:SetPoint("LEFT", 88, 0); r.a:SetWidth(260); r.a:SetJustifyH("LEFT"); r.a:SetWordWrap(false)
        r.b = K.Text(r, "GameFontHighlightSmall"); r.b:SetPoint("LEFT", 354, 0); r.b:SetPoint("RIGHT", -6, 0); r.b:SetJustifyH("LEFT"); r.b:SetWordWrap(false)
        r:SetScript("OnEnter", function(s)
            local it = s.item
            if it and it.itemID then if _G.VoidTip then VoidTip.Place(s) else GameTooltip:SetOwner(s, "ANCHOR_RIGHT") end; GameTooltip:SetItemByID(it.itemID); if it.tip then GameTooltip:AddLine(it.tip, 0.8, 0.8, 0.8, true) end GameTooltip:Show()
            elseif it and it.tip then GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine(it.a or "", 1, 1, 1); GameTooltip:AddLine(it.tip, 0.8, 0.8, 0.8, true); GameTooltip:Show() end
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnClick", function(s) if s.item and s.item.onClick then s.item.onClick() end end)
    end, function(r, it, i)
        r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.035 or 0)
        r.t:SetText(it.t or ""); r.a:SetText(it.a or ""); r.b:SetText(it.b or "")
    end)
    local function render()
        if not P:IsVisible() then return end
        local H = HH()
        if not H then return end
        P.head:SetText(headFn(H))
        local n = select(2, P.head:GetText():gsub("\n", "")) + 1
        P.list:ClearAllPoints()
        P.list:SetPoint("TOPLEFT", 8, -(20 + n * 16)); P.list:SetPoint("BOTTOMRIGHT", -12, 10)
        P.list:SetData(itemsFn(H), true)
    end
    P:SetScript("OnShow", render)
    local H = HH()
    if H and H.OnChange then H.OnChange(function() render() end) end
    return P
end

local function amount(e)
    local parts = {}
    if e.rp and e.rp ~= 0 then parts[#parts + 1] = GOLD .. ("%+d Rank Points|r"):format(e.rp) end
    if e.honor and e.honor ~= 0 then parts[#parts + 1] = ("%+d Honor"):format(e.honor) end
    if e.hk and e.hk > 0 then parts[#parts + 1] = ("%d kill%s"):format(e.hk, e.hk > 1 and "s" or "") end
    if e.rep then parts[#parts + 1] = K.GREY .. e.rep .. "|r" end
    return table.concat(parts, ", ")
end

local function LogBuild(host)
    return ListPanel(host, function(H)
        local r = H.Rank()
        return CYAN .. "Did it count?|r  " .. K.GREY .. "every change to your Rank Points, Honor and PvP reputations, with what caused it|r"
            .. (r and ("\n%s Rank Points this week, %s to the cap."):format(H.Num(r.rp), r.atCap and "none left" or H.Num(r.room or 0)) or "")
    end, function(H)
        local out = {}
        for _, e in ipairs(H.Log()) do
            local b
            if e.kind == "zero" then b = RED .. "no Rank Points|r  " .. K.GREY .. (e.why or "") .. "|r"
            elseif e.kind == "week" then b = ""
            elseif e.kind == "spent" then b = K.GREY .. amount(e) .. "|r"
            else b = amount(e) .. (e.why and (RED .. "  no Rank Points: |r" .. K.GREY .. e.why .. "|r") or "") end
            out[#out + 1] = { t = date("%a %H:%M", e.at), a = (e.kind == "week" and CYAN or "") .. (e.what ~= "" and e.what or "?") .. (e.kind == "week" and "|r" or ""),
                b = b, tip = e.why }
        end
        if #out == 0 then out[1] = { a = K.GREY .. "nothing yet|r", b = K.GREY .. "a Field of Honor turn-in, a battleground or an honorable kill shows up here|r" } end
        return out
    end)
end

local function BgBuild(host)
    return ListPanel(host, function(H)
        local lines = { CYAN .. "Battlegrounds|r  " .. K.GREY .. "what each match really gave you (entering to leaving)|r" }
        local maps, seen = {}, {}
        for _, b in ipairs(H.Matches(true)) do if not seen[b.map] then seen[b.map] = true; maps[#maps + 1] = b.map end end
        local avg = {}
        for _, m in ipairs(maps) do
            local ms = H.Measured(m)
            if ms.win or ms.loss then
                avg[#avg + 1] = ("%s: win %s, loss %s"):format(m, ms.win and (GOLD .. H.Num(ms.win) .. "|r (" .. ms.wins .. ")") or "-",
                    ms.loss and (GOLD .. H.Num(ms.loss) .. "|r (" .. ms.losses .. ")") or "-")
            end
        end
        lines[#lines + 1] = #avg > 0 and ("Average Rank Points: " .. table.concat(avg, "   ·   "))
            or (K.GREY .. ("No matches logged yet. Until then the planner uses a guide number: about %d Rank Points a win, %d a loss."):format(H.GUIDE.win, H.GUIDE.loss) .. "|r")
        local cur = H.InMatch()
        if cur then lines[#lines + 1] = GOLD .. "Now: " .. cur.map .. "|r" .. K.GREY .. " (counted when you leave)|r" end
        return table.concat(lines, "\n")
    end, function(H)
        local out = {}
        for _, b in ipairs(H.Matches()) do
            local res = b.won == true and (GREEN .. "won|r") or b.won == false and (RED .. "lost|r") or (K.GREY .. "left|r")
            out[#out + 1] = { t = date("%a %H:%M", b.at), a = ("%s  %s  %s%d min|r"):format(b.map or "?", res, K.GREY, b.mins or 0),
                b = amount(b) .. (b.why and (RED .. "  no Rank Points|r") or ""),
                tip = b.why and ("No Rank Points: " .. b.why) or (b.atCap and "You were at this week's cap." or nil) }
        end
        if #out == 0 then out[1] = { a = K.GREY .. "no battlegrounds yet|r", b = K.GREY .. "join one: it's logged when you leave|r" } end
        return out
    end)
end

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
----------------------------------------------------------------------
-- World PvP: your honorable kills outside battlegrounds (today, this week, by zone), a weekly that asks for kills,
-- and the "danger here" line from the world PvP code (VoidBounty's, moved in)
----------------------------------------------------------------------
local function BH() return _G.VoidBountyHub end

local function WorldBuild(host)
    local P = ListPanel(host, function(H)
        local k = H.Kills()
        local N = H.Num
        local lines = {
            CYAN .. "World PvP|r  " .. K.GREY .. "honorable kills outside battlegrounds give Honor, not Rank Points|r",
            ("Honorable kills: %stoday %s|r  ·  %sthis week %s|r (%s Honor)  ·  in battlegrounds this week %s  ·  lifetime %s"):format(
                GOLD, N(k.today), GOLD, N(k.week), N(k.weekHonor), N(k.bgWeek), N(k.lifetime)),
        }
        if k.weekly then
            lines[#lines + 1] = ("%s%s|r: %s"):format(GOLD, k.weekly.title, ((k.weekly.obj or ""):gsub("\n", "  ·  ")))
        end
        local B = BH()
        if B and B.Danger then
            local ok, s = pcall(B.Danger)
            if ok and s then lines[#lines + 1] = s end
        end
        return table.concat(lines, "\n")
    end, function(H)
        local k = H.Kills()
        local out = {}
        if #k.zones > 0 then
            out[#out + 1] = { a = CYAN .. "This week by zone|r" }
            for _, z in ipairs(k.zones) do
                out[#out + 1] = { t = date("%a %H:%M", z.last), a = z.zone, b = ("%d kill%s, %s Honor"):format(z.n, z.n == 1 and "" or "s", H.Num(z.honor)) }
            end
        end
        if #k.recent > 0 then
            out[#out + 1] = { a = CYAN .. "Recent kills|r" }
            for _, e in ipairs(k.recent) do
                out[#out + 1] = { t = date("%a %H:%M", e.at), a = e.zone .. ((e.sub and e.sub ~= "" and e.sub ~= e.zone) and (K.GREY .. "  " .. e.sub .. "|r") or ""),
                    b = ("%d kill%s%s"):format(e.n, e.n == 1 and "" or "s", (e.honor or 0) > 0 and (", +" .. e.honor .. " Honor") or "") }
            end
        end
        if #out == 0 then
            out[1] = { a = K.GREY .. "no world kills logged yet|r", b = K.GREY .. "an honorable kill outside a battleground shows up here, with its zone|r" }
        end
        return out
    end)
    return P
end

----------------------------------------------------------------------
-- Honor shop: what your Honor buys, for your class. Vendors from VoidDB (who sells what and where); prices learned
-- when a vendor is opened (VoidHonor/Shop.lua). Click a vendor you haven't opened: the way there.
----------------------------------------------------------------------
local function ItemName(e)
    local name = (C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)) or e.name or ("item " .. e.id)
    local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(e.id)
    local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if C_Item.RequestLoadItemDataByID and not C_Item.GetItemNameByID(e.id) then C_Item.RequestLoadItemDataByID(e.id) end
    return (c and c.hex or "|cffffffff") .. name .. "|r" .. (e.owned and (K.GREY .. "  (owned)|r") or "")
end
local function Cost(H, e)
    local s = GOLD .. H.Num(e.honor) .. " Honor|r"
    for _, o in ipairs(e.other or {}) do s = s .. (" + %d %s"):format(o.value or 0, o.name or "?") end
    return s
end

local function ShopBuild(host)
    return ListPanel(host, function(H)
        local s = H.Shop()
        return CYAN .. "Honor shop|r  " .. K.GREY .. "PvP vendors' items your class can use, by what your Honor buys|r\n"
            .. ("You have %s%s Honor|r  " .. K.GREY .. "\194\183  prices from %d vendor%s you've opened|r"):format(GOLD, H.Num(s.have), s.vendors, s.vendors == 1 and "" or "s")
    end, function(H)
        local s = H.Shop()
        local out = {}
        local function head(text) out[#out + 1] = { a = CYAN .. text .. "|r" } end
        if #s.now > 0 then
            head(("Can buy now (%d)"):format(#s.now))
            for _, e in ipairs(s.now) do
                out[#out + 1] = { t = e.slot, a = ItemName(e), b = Cost(H, e) .. K.GREY .. "  \194\183 " .. e.vendor .. "|r", itemID = e.id,
                    tip = e.vendor .. (e.where and e.where ~= "" and (", " .. e.where) or "") }
            end
        end
        if #s.save > 0 then
            head(("Save up (%d)"):format(#s.save))
            for _, e in ipairs(s.save) do
                local need = {}
                if e.more > 0 then need[1] = H.Num(e.more) .. " more Honor" end
                for _, s2 in ipairs(e.short or {}) do need[#need + 1] = s2 end
                out[#out + 1] = { t = e.slot, a = ItemName(e), b = Cost(H, e) .. "  |cffff9944" .. table.concat(need, ", ") .. "|r", itemID = e.id,
                    tip = e.vendor .. (e.where and e.where ~= "" and (", " .. e.where) or "") }
            end
        end
        if #s.rank > 0 then
            head(("Locked: rank, level or rep (%d)"):format(#s.rank))
            for _, e in ipairs(s.rank) do
                out[#out + 1] = { t = e.slot, a = ItemName(e), b = "|cffff9944" .. (e.block or "?") .. "|r  " .. Cost(H, e), itemID = e.id,
                    tip = table.concat(e.req or {}, "\n") }
            end
        end
        if #s.unseen > 0 then
            head(("Vendors to open once (%d)"):format(#s.unseen))
            for _, u in ipairs(s.unseen) do
                out[#out + 1] = { t = "vendor", a = u.name, b = ("%s  " .. K.GREY .. "\194\183 %s \194\183 %d items for you  (click: the way)|r"):format(u.zone, u.title, u.usable),
                    tip = "Click: a pin to this vendor. Open their window once and every price shows here.",
                    onClick = function() H.ShopGo(u) end }
            end
        end
        if #out == 0 then out[1] = { a = K.GREY .. "no PvP vendor known for your side yet|r" } end
        return out
    end)
end

----------------------------------------------------------------------
-- PvP quests: every WoW Forever PvP quest for your side (VoidHonor/Quests.lua), per battleground, with what it
-- means for you now. Click one: the way to its giver (or, in your log, to where it's handed in).
----------------------------------------------------------------------
local QSTATE = { log = { "in log", "|cffffd27a" }, open = { "open", "|cff55ff55" }, ["repeat"] = { "repeat", "|cff00c7ff" },
    locked = { "locked", "|cffff9944" }, done = { "done", "|cff8c8c9e" } }

local function QuestsBuild(host)
    return ListPanel(host, function(H)
        if not H.Quests then return CYAN .. "PvP quests|r" end
        local s = H.Quests()
        local marks = {}
        for _, m in ipairs(s.marks) do
            local short = ({ ["Warsong Gulch"] = "WSG", ["Arathi Basin"] = "AB", ["Alterac Valley"] = "AV", ["Darkspear Islands"] = "DI" })[m.bg] or m.bg
            marks[#marks + 1] = ("%s %s%d|r"):format(short, m.n > 0 and GOLD or K.GREY, m.n)
        end
        return CYAN .. "PvP quests|r  " .. K.GREY .. "every battleground quest for your side; click one for the way to its giver|r\n"
            .. "Marks: " .. table.concat(marks, "   ") .. K.GREY .. ("   \194\183  %d in your log, %d open, %d done|r"):format(s.counts.log or 0, s.counts.open or 0, s.counts.done or 0)
    end, function(H)
        if not H.Quests then return { { a = K.GREY .. "VoidHonor isn't loaded|r" } } end
        local s = H.Quests()
        local out = {}
        for _, g in ipairs(s.groups) do
            local open = 0
            for _, r in ipairs(g.rows) do if r.state ~= "done" then open = open + 1 end end
            out[#out + 1] = { a = CYAN .. g.name .. "|r" .. K.GREY .. ("  (%d of %d to do)"):format(open, #g.rows) .. "|r" }
            for _, r in ipairs(g.rows) do
                local q, st = r.q, QSTATE[r.state] or QSTATE.open
                local who = (r.state == "log" and q.turnin ~= "" and ("hand in: " .. q.turnin)) or (q.giver ~= "" and q.giver) or ""
                local b = H.QuestReward(q)
                if r.state == "locked" then b = "|cffff9944needs " .. (r.lock or "?") .. "|r" .. (b ~= "" and ("  " .. K.GREY .. b .. "|r") or "") end
                if who ~= "" then b = b .. K.GREY .. "  \194\183 " .. who .. "|r" end
                -- the tooltip names where the click goes: the turn-in for a quest in your log, else the giver
                local toTurnin = r.state == "log" and q.tm ~= nil
                local dm, dwho = (toTurnin and q.tm or q.m), (toTurnin and q.turnin or q.giver)
                local mapName = dm and C_Map and C_Map.GetMapInfo and (C_Map.GetMapInfo(dm) or {}).name
                out[#out + 1] = { t = st[2] .. st[1] .. "|r", a = (r.state == "done" and K.GREY or "|cffffffff") .. q[1] .. "|r", b = b,
                    tip = (dwho ~= "" and ((toTurnin and "Hand in: " or "") .. dwho .. (mapName and (", " .. mapName) or "")) or "giver not known yet")
                        .. (dm and "\nClick: the way there." or ""),
                    onClick = q.m and function() H.QuestGo(r) end or nil }
            end
        end
        if #out == 0 then out[1] = { a = K.GREY .. "no PvP quests known|r" } end
        return out
    end)
end

local function SettingsBuild(host)
    local function C() return HH().Char() end
    local blocks = {
        { title = "Battleground box", items = {
            { "check", "Show the box in battlegrounds", function() local d = VoidHonorDB and VoidHonorDB.bgbox; return not (d and d.off) end,
              function(on) local H = HH(); if H and H.BgSlash then H.BgSlash(on and "box on" or "box off") end end,
              "A thin strip at the top of the screen in every battleground: the score, Shout plan and Voice. Open it for the call buttons (Inc, Inc 3+, Help, Safe per base). Every call is your click, sent to battleground chat." },
            { "button", "Set my voice link", function() local H = HH(); if H and H.AskVoiceLink then H.AskVoiceLink() end end,
              "Your own Discord invite. The Voice button in the box posts it to battleground chat when you click it." },
        } },
        { title = "Chat", items = {
            { "check", "A chat line when Rank Points or Honor change", function() return C().chat ~= false end, function(on) C().chat = on end,
              "\"+500 Rank Points, +300 Honor - Field of Honor: Week 1 (7,175 to this week's cap)\", and why when a weekly gave none." },
            { "check", "A chat line after each battleground", function() return C().chatMatch ~= false end, function(on) C().chatMatch = on end,
              "The map, won or lost, Rank Points, Honor and kills, and how much room is left this week." },
        } },
        { title = "About", items = {
            { "note", "Your rank, cap and weeks are read from the game itself (the same numbers as the PvP tab). Rank Points per battleground "
                .. "aren't given by the game, so VoidHonor measures them from your own matches. Your rank and battleground log stay on your computer. World PvP shares sightings and deaths with your side only while those settings are on.", h = 84 },
        } },
    }
    -- the world PvP settings (VoidBounty's, moved in 11-27): the nearby warning, sharing, layer help, Try it
    if BH() and ns.BountySettingsBlocks then
        for i, b in ipairs(ns.BountySettingsBlocks()) do table.insert(blocks, i + 1, b) end
    end
    return K.SettingsPage(host, blocks, 420)
end

ns.RegisterPage("VoidHonor", {
    available = function() return HH() ~= nil end,
    sections = function()
        local out = {
            { key = "plan", label = "Planner", build = PlanBuild },
            { key = "log", label = "Did it count", build = LogBuild },
            { key = "bgs", label = "Battlegrounds", build = BgBuild },
            { key = "world", label = "World PvP", build = WorldBuild },
            { key = "shop", label = "Honor shop", build = ShopBuild },
            { key = "quests", label = "PvP quests", build = QuestsBuild },
        }
        -- VoidBounty's lists (Blood debts, Sightings, Most wanted; with writs on: My hunts, Ledger), from its own builders
        local B = BH()
        if B and B.NAV and B.Items and ns.BountyList then
            local LABEL = { debts = "Blood debts", sightings = "Sightings", hall = "Most wanted", hunts = "My hunts", ledger = "Ledger" }
            local order = { "debts", "sightings", "hall", "hunts", "ledger" }
            local inNav = {}
            for _, n in ipairs(B.NAV()) do inNav[n[1]] = true end
            for _, id in ipairs(order) do
                if inNav[id] and B.Items[id] then out[#out + 1] = { key = "b_" .. id, label = LABEL[id], build = ns.BountyList(id) } end
            end
        end
        out[#out + 1] = { key = "settings", label = "Settings", build = SettingsBuild }
        return out
    end,
})
