-- VoidSequencer — your own rotations (2026-11-25, the user: "if people dont like the suggested rotation we have to
-- provide a way for them to build there own, completely" + "it needs to be easy for players to figure out").
--
-- Per character and per spec (WoW Forever: per class) you can keep any number of named rotations of your own next
-- to the suggested one. Each holds everything key 1 does: the single-target and AoE steps, the "every press" lines
-- (what runs before each step: /petattack, /startattack, Auto Shot...) and the Alt / Ctrl / Shift casts.
--   * The suggested rotation is never edited in place: your first edit makes your own copy of it, so an update to the
--     suggested one can never wipe your work (it used to: "a new version replaces old edits").
--   * Share a rotation as plain text (Export / Import): readable, so it can be pasted in Discord and checked by eye.
-- Pure data code (no frames): VoidSequencer.lua runs the active one; Options.lua draws the controls.
-- Test: go run ./tools/cmd/vseq-mine-test
local _, VS = ...
VS = VS or {}
local M = {}
VS.Mine = M

M.HEADER = "VoidSequencer rotation"
M.VERSION = 1
M.SEP = " ;; "               -- between the spells / lines of one step in the text format
M.MAX_NAME = 40
M.MAX_STEPS = 40
M.MAX_PER_STEP = 10
M.MAX_HEAD = 8

-- ---------------------------------------------------------------------------
-- Cleaning: names, one entry (a spell or a macro line), the "every press" lines
-- ---------------------------------------------------------------------------
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function M.CleanName(s)
    s = tostring(s or ""):gsub("[%c|]", "")
    s = trim((s:gsub("%]=*%]", "")))
    if s == "" then s = "My rotation" end
    return s:sub(1, M.MAX_NAME)
end

-- The secure loader wraps every macro in a long string ([=======[ ... ]=======]): no entry may close it early, whoever
-- wrote it (an imported rotation comes from another player). One line, at most a macro's 255 characters.
function M.CleanEntry(s)
    s = tostring(s or ""):gsub("[\r\n]", " "):gsub("%]=*%]", "")
    -- not even half a closer: a "]===" at the end would join the loader's own "]=======]" (Codex, 2026-11-25)
    s = s:gsub("%]=+", "]")
    -- " ;; " splits a step's spells in the shared text; inside one line ";;" is only an empty clause, so drop it
    while s:find(";%s*;") do s = s:gsub(";%s*;", ";") end
    return trim(s):sub(1, 255)
end

function M.CleanLines(text)
    local out = {}
    local s = tostring(text or "")
    s = s:gsub("\r", "")
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        line = M.CleanEntry(line)
        if line ~= "" and #out < M.MAX_HEAD then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

-- no size limits here: your own lists are never cut (M.Parse limits what comes in as shared text)
local function copySeq(src)
    local out = {}
    for _, step in ipairs(src or {}) do
        local s = {}
        for _, e in ipairs(step) do
            s[#s + 1] = M.CleanEntry(e)
        end
        if #s == 0 then s[1] = "" end
        out[#out + 1] = s
    end
    if #out == 0 then out[1] = { "" } end
    return out
end
M.CopySeq = copySeq

local function copyMods(m)
    local function one(v) v = M.CleanEntry(v); return v ~= "" and v or nil end
    return { alt = one(m and m.alt), ctrl = one(m and m.ctrl), shift = one(m and m.shift) }
end

-- ---------------------------------------------------------------------------
-- Storage: VoidSequencerDB.mine[slot] = { list = { rotation... }, active = name or nil }
-- slot = the spec ("Unholy", "Frost") or the WoW Forever class key ("FOREVER_HUNTER").
-- ---------------------------------------------------------------------------
local function store(slot, create)
    local db = VoidSequencerDB
    if not (db and slot) then return nil end
    db.mine = db.mine or {}
    local s = db.mine[slot]
    if not s and create then s = { list = {} }; db.mine[slot] = s end
    return s
end

function M.List(slot) local s = store(slot); return s and s.list or {} end

function M.Find(slot, name)
    for i, r in ipairs(M.List(slot)) do if r.name == name then return r, i end end
end

-- the running rotation of your own for this slot, or nil (the suggested one runs)
function M.Active(slot)
    local s = store(slot)
    if not (s and s.active) then return nil end
    local r = M.Find(slot, s.active)
    if not r then s.active = nil end
    return r
end

function M.SetActive(slot, name)
    local s = store(slot, true)
    if not s then return end
    s.active = (name and M.Find(slot, name)) and name or nil
end

function M.UniqueName(slot, base)
    base = M.CleanName(base)
    local n, i = base, 2
    while M.Find(slot, n) do
        local tail = " (" .. i .. ")"
        n = base:sub(1, M.MAX_NAME - #tail) .. tail
        i = i + 1
    end
    return n
end

-- a new rotation of your own; info = { from = the suggested rotation it was copied from, fromRev = its version }
function M.Create(slot, name, st, aoe, head, mods, info)
    local s = store(slot, true)
    if not s then return nil end
    local r = {
        name = M.UniqueName(slot, name),
        st = copySeq(st), aoe = copySeq(aoe),
        head = M.CleanLines(head),
        mods = copyMods(mods),
        from = info and info.from, fromRev = info and info.fromRev,
    }
    s.list[#s.list + 1] = r
    return r
end

function M.Rename(slot, old, new)
    local r = M.Find(slot, old)
    if not r then return nil end
    new = M.CleanName(new)
    if new ~= old and M.Find(slot, new) then new = M.UniqueName(slot, new) end
    r.name = new
    local s = store(slot)
    if s.active == old then s.active = new end
    return new
end

function M.Delete(slot, name)
    local _, i = M.Find(slot, name)
    if not i then return false end
    local s = store(slot)
    table.remove(s.list, i)
    if s.active == name then s.active = nil end
    return true
end

-- ---------------------------------------------------------------------------
-- Sharing as text. Example:
--   VoidSequencer rotation 1
--   name: My Hunter
--   class: HUNTER
--   for: FOREVER_HUNTER
--   every press: /petattack [@target,harm,nodead]
--   alt: Feign Death
--   st: Raptor Strike ;; Arcane Shot
--   aoe: Multi-Shot ;; Arcane Shot
-- One "st:" / "aoe:" line per step, its spells (or macro lines) split by " ;; ", top = first.
-- ---------------------------------------------------------------------------
function M.Export(r, class, forKey)
    local out = { M.HEADER .. " " .. M.VERSION, "name: " .. r.name }
    if class then out[#out + 1] = "class: " .. class end
    if forKey then out[#out + 1] = "for: " .. forKey end
    for line in ((r.head or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then out[#out + 1] = "every press: " .. line end
    end
    for _, k in ipairs({ "alt", "ctrl", "shift" }) do
        if r.mods and r.mods[k] then out[#out + 1] = k .. ": " .. r.mods[k] end
    end
    for _, mode in ipairs({ "st", "aoe" }) do
        for _, step in ipairs(r[mode] or {}) do
            local parts = {}
            for _, e in ipairs(step) do if e ~= "" then parts[#parts + 1] = e end end
            out[#out + 1] = mode .. ": " .. table.concat(parts, M.SEP)
        end
    end
    return table.concat(out, "\n")
end

-- text -> { name, class, for, head, mods, st, aoe } or nil, "what's wrong" (in plain words for the player)
function M.Parse(text)
    text = tostring(text or ""):gsub("\r", "")
    local r = { st = {}, aoe = {}, mods = {}, head = {} }
    local sawHeader = false
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = trim(raw)
        if line ~= "" then
            if not sawHeader then
                local v = line:match("^" .. M.HEADER .. "%s+(%d+)")
                if not v then return nil, "That isn't a VoidSequencer rotation: the first line should start with \"" .. M.HEADER .. "\"." end
                if tonumber(v) > M.VERSION then return nil, "That rotation comes from a newer VoidSequencer: update the addon first." end
                sawHeader = true
            else
                local key, val = line:match("^([%a ]+):%s*(.*)$")
                key = key and trim(key):lower()
                if key == "name" then r.name = val
                elseif key == "class" then r.class = trim(val):upper()
                elseif key == "for" then r.forKey = trim(val)
                elseif key == "every press" then r.head[#r.head + 1] = val
                elseif key == "alt" or key == "ctrl" or key == "shift" then r.mods[key] = val
                elseif key == "st" or key == "aoe" then
                    local step = {}
                    for part in (val .. M.SEP):gmatch("(.-)" .. M.SEP:gsub("%p", "%%%0")) do
                        part = M.CleanEntry(part)
                        if part ~= "" and #step < M.MAX_PER_STEP then step[#step + 1] = part end
                    end
                    if #step == 0 then step[1] = "" end
                    if #r[key] < M.MAX_STEPS then r[key][#r[key] + 1] = step end
                end   -- anything else: a line from a newer version, skipped
            end
        end
    end
    if not sawHeader then return nil, "Nothing to import: paste the whole text, starting with \"" .. M.HEADER .. "\"." end
    local any = false
    for _, mode in ipairs({ "st", "aoe" }) do
        for _, step in ipairs(r[mode]) do for _, e in ipairs(step) do if e ~= "" then any = true end end end
    end
    if not any then return nil, "That rotation has no spells in it." end
    r.name = M.CleanName(r.name or "Imported rotation")
    r.head = M.CleanLines(table.concat(r.head, "\n"))
    if #r.st == 0 then r.st = { { "" } } end
    if #r.aoe == 0 then r.aoe = { { "" } } end
    return r
end

-- Import into a slot; returns the rotation and a warning (another class's rotation) or nil, the error
function M.Import(slot, text, myClass)
    local p, err = M.Parse(text)
    if not p then return nil, err end
    local warn
    if p.class and myClass and p.class ~= myClass then
        warn = ("It was made for a %s: spells your class doesn't have are skipped."):format(p.class:sub(1, 1) .. p.class:sub(2):lower())
    end
    local r = M.Create(slot, p.name, p.st, p.aoe, p.head, p.mods)
    return r, warn
end
