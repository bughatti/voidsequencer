-- VoidSequencer — a lean one-button rotation sequencer.
--
-- Mechanism (the standard, allowed one for one-button addons): a SecureActionButton whose "macrotext"
-- is rewritten on each click by a secure wrap-script that walks a list of
-- priority-stacked macro blocks. Each block is several "/cast" lines; WoW casts
-- the FIRST castable spell, so cooldowns/execute-gates self-skip and presses
-- aren't wasted. Sequencing across blocks weaves in wound-building so we don't
-- always-Scourge-Strike. Hold SHIFT to switch the spend/AoE lines to AoE.
--
-- v1 spec: Unholy DK (Rider build), ratios derived from a #2-caliber M+ log.
-- Big cooldowns (Army, etc.) are intentionally NOT in the auto-sequence — press
-- those yourself on pull so they're never wasted mid-pack.

local ADDON, VS = ...
VS = VS or {} -- shared namespace for sibling files (Minimap.lua, Options.lua)
-- key 1 by default: a new character had no key at all, and VoidBars leaves key 1 to us,
-- so nothing was bound (2026-10-29). Disabling still gives the old binding back (keyOrig).
local DB_DEFAULTS = { key = "1", point = { "CENTER", 0, -150 }, aoe = false, mods = {}, enabled = true, keyOrig = nil }

-- ---------------------------------------------------------------------------
-- Sequences. TWO full rotations (ST and AoE), switched by an in-combat toggle
-- (NOT a held modifier). Design rules proven by the SavedVariables logs:
--   * Never LEAD a step with a cooldown ability (Soul Reaper/Army/DT/D&D) — a CD
--     failure dead-ends the macro. Cooldowns go behind [mod] (true no-ops that
--     fall through), so the unconditional spender always fires.
--   * Resource failures DO fall through, so each step ends with a primary spender
--     + a resource alternative (Death Coil dumps RP when rune-starved, etc.).
-- Modifiers (work in BOTH modes):
--   hold ALT  -> big cooldowns (Army of the Dead, Dark Transformation)
--   hold CTRL -> Soul Reaper (TAP it during execute / when up — don't HOLD it)
-- ---------------------------------------------------------------------------
-- Cooldowns are AUTOMATIC via dedicated single-ability steps. Because you spam
-- ~2x the GCD, a step that can't fire yet (CD not ready / not in execute) just
-- BOUNCES and the next press fills the GCD — so a lone cooldown step casts the
-- instant it's available and costs ~nothing otherwise. This was the trap with
-- Soul Reaper ONLY because it led every step; one CD per step is free.
-- Army of the Dead stays on ALT so you align it with pulls/burst.
-- Sequences are now DATA (lists of spell names), stored in SavedVariables and
-- editable in the options panel. Each "step" is a priority stack: WoW casts the
-- FIRST castable spell in the step, the rest are fallbacks. The DEFAULT_* tables
-- below only SEED an empty SV — once seeded, the user's edits are authoritative.
--
-- The macro text is GENERATED from these lists at load time (stepToMacro):
--   * CONDITIONALS auto-applies known targeting (e.g. Death and Decay -> @player)
--     so the guided picker never has to expose macro syntax.
--   * Army of the Dead is a GLOBAL [mod:alt] prepend (DB.armyOnAlt), not a step,
--     so holding Alt fires it at any point in either rotation.
--
-- Default ratios derived from a #2-caliber M+ log; SR x2 + extra Festering added
-- 2026-06-12 after a side-by-side test (SR 12 vs 25, Festering 17 vs 52).

-- Spells that need an auto-applied macro conditional (picker stays spell-only).
local CONDITIONALS = {
	["Death and Decay"] = "[@player]",
	["Defile"]          = "[@player]",
	-- Resto Druid heals: cast on the friendly you're HOVERING (a VuhDo / raid-frame
	-- box), else your friendly target, else yourself. This is the whole point of the
	-- heal profile -- you aim with the cursor, the button picks the spell. @mouseover
	-- is a secure TARGETING conditional (not a data read), so it's taint-safe in 12.x.
	["Rejuvenation"]    = "[@mouseover,help][help][@player]",
	["Regrowth"]        = "[@mouseover,help][help][@player]",
	["Swiftmend"]       = "[@mouseover,help][help][@player]",
	["Lifebloom"]       = "[@mouseover,help][help][@player]",
	["Wild Growth"]     = "[@mouseover,help][help][@player]",
	["Grove Guardians"] = "[@mouseover,help][help][@player]",
	-- Defensive externals cast on a hovered raid frame (used as modifier casts).
	["Ironbark"]        = "[@mouseover,help][help][@player]",
	-- WoW Forever Paladin: solo-leveling self-heal / self-defensive on a held modifier.
	-- Plain @player keeps the macro short (Forever steps are near the 255-char cap).
	["Holy Light"]        = "[@player]",
	["Flash of Light"]    = "[@player]",
	["Divine Protection"] = "[@player]",
}

-- Spells that fail with a dagger in the MAIN hand ("Must have a One-Handed Melee
-- Weapon equipped in the main hand" -- Outlaw's Blade Rush, cast log 2026-10-24).
-- No macro conditional checks one hand ([equipped:Daggers] also matches an off-hand
-- dagger, the usual Outlaw axe + dagger), so these lines are left out of the macro
-- while the main hand is a dagger; PLAYER_EQUIPMENT_CHANGED rebuilds.
local NO_DAGGER_MH = { ["Blade Rush"] = true }
local function MainHandIsDagger()
	local id = GetInventoryItemID("player", INVSLOT_MAINHAND or 16)
	if not id then return false end
	local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
	return classID == Enum.ItemClass.Weapon and subClassID == Enum.ItemWeaponSubclass.Dagger
end

-- Per-spec defaults, keyed by the spec NAME from GetSpecializationInfo
-- ("Unholy", "Guardian", ...). Each entry has st/aoe sequences + a `mods` string
-- of the reactive cooldowns/defensives you control by HAND (held modifiers,
-- never blind-auto). Seeding picks the entry matching the character's CURRENT
-- spec, so the same addon works on every character/spec automatically.
-- Outlaw's builder -> finisher order (see Outlaw rev 4): advances only when a cast lands.
-- Healer targeting (Restoration rev 2): heal the friendly you hover, else your friendly
-- target; damage the enemy you hover, else your enemy target. No match -> the line is
-- skipped (not a failed cast), so a step's heal falls through to its damage spell.
local HEAL_HOVER = "[@mouseover,help,nodead][help,nodead]"
local DMG_HOVER = "[@mouseover,harm,nodead][harm,nodead]"
-- Rejuvenation on a fixed group member, no aiming (the ramp spread). Raw line, so it
-- carries its own channel guard. Missing unit (solo / small group) -> skipped.
local function REJUV_ON(unit)
	return "/cast [nochanneling,@" .. unit .. ",help,nodead] Rejuvenation"
end

-- Restoration's single loop (rev 3). "Hover" steps hit whoever you hover (else your
-- friendly target, else you); REJUV_ON steps spread Rejuvenation with no aiming (5 out =
-- Abundance). Swiftmend is always followed by Regrowth on the hovered ally (Soul of the
-- Forest + Power of the Archdruid: it copies to 2 nearby). Each step's damage spell fires
-- instead when you hover / target an enemy and no friendly.
-- rev 4 (2026-10-27, mash-friendly; the player mashes key 1): rev 3 gave Swiftmend and
-- Wild Growth ONE try per loop, and a press that lands in the global cooldown lost that
-- try ("Not yet recovered" x20 in one run), so they -- and the treants they summon --
-- mostly vanished. The hovered-ally heals now live in a /castsequence, which only moves
-- on when a cast LANDS: a GCD-blocked press retries the same spell next time. Rejuvenation
-- sits right before Swiftmend (it needs a HoT on the target). Damage stays the fallback
-- when no friendly is hovered/targeted. 15 steps (odd), so a steady mash rhythm can't
-- phase-lock onto the same steps; every third step spreads Rejuvenation to the group.
local RESTO_CORE = "/castsequence [nochanneling,@mouseover,help][nochanneling,help] reset=combat "
	.. "Rejuvenation, Swiftmend, Regrowth, Wild Growth, Rejuvenation, Regrowth, Rejuvenation, Regrowth"
local RESTO_LOOP = {
	{ RESTO_CORE, "Wrath" },
	{ RESTO_CORE, "Wrath" },
	{ REJUV_ON("party1"), "Starsurge" },
	{ RESTO_CORE, "Wrath" },
	{ RESTO_CORE, "Wrath" },
	{ REJUV_ON("party2"), "Wrath" },
	{ RESTO_CORE, "Moonfire" },
	{ RESTO_CORE, "Wrath" },
	{ REJUV_ON("party3"), "Starsurge" },
	{ RESTO_CORE, "Wrath" },
	{ RESTO_CORE, "Wrath" },
	{ REJUV_ON("party4"), "Wrath" },
	{ RESTO_CORE, "Wrath" },
	{ RESTO_CORE, "Wrath" },
	{ REJUV_ON("player"), "Wrath" },
}

-- Restoration's cat weave (2026-10-27): what the top Resto druids' logs show between heals
-- (Rake, Rip, Shred, the odd Ferocious Bite). Rake + 4 Shred = 5 combo points -> Rip; Rake
-- + 3 Shred -> Ferocious Bite. A castsequence only advances on a landed cast, so energy
-- starvation just retries; spells you don't know are trimmed (trimSequence).
local RESTO_CAT = "/castsequence reset=combat Rake, Shred, Shred, Shred, Shred, Rip, Rake, Shred, Shred, Shred, Ferocious Bite"

local OUTLAW_CORE = "/castsequence reset=combat Sinister Strike, Sinister Strike, Pistol Shot, Sinister Strike, Dispatch"
-- Assassination / Subtlety cores (see their rev 1 notes). Keep each macro under 255 chars.
local ASSA_CORE = "/castsequence reset=combat Garrote, Mutilate, Mutilate, Rupture, Mutilate, Mutilate, Envenom, "
	.. "Mutilate, Mutilate, Envenom, Mutilate, Mutilate, Envenom"
-- Midnight (Blizzard's pre-expansion notes): Crimson Tempest awards 1 combo point and
-- copies your longest Garrote / Rupture onto 2 more enemies, so it's a builder that needs
-- Garrote + Rupture up first.
local ASSA_AOE = "/castsequence reset=combat Garrote, Fan of Knives, Fan of Knives, Rupture, Crimson Tempest, "
	.. "Fan of Knives, Fan of Knives, Envenom, Crimson Tempest, Fan of Knives, Fan of Knives, Fan of Knives, Envenom"
-- Subtlety lost Rupture and Symbols of Death in Midnight: Eviscerate is the finisher.
-- Top players' casts (Mythic Sszorak + Entombed Sentinels, 2026-10-26): at 90
-- builders and finishers are ~1:1 -- Eviscerate/Coup de Grace about as often as Backstab
-- + Shadowstrike together, inside and outside Dance. So one builder -> one finisher.
-- Shadowstrike is its own spell, NOT an override of Backstab (stealth / Shadow Dance only
-- page the action bar), so stealth and Dance get their own clause. Shadow Dance turns on
-- [bonusbar:1], not [stealth]. Each clause has its own place (one Eviscerate advances
-- both when both wait on it).
local SUB_CORE = "/castsequence [stealth][bonusbar:1] reset=combat Shadowstrike, Eviscerate; "
	.. "reset=combat Backstab, Eviscerate"
-- AoE in the same logs: Shuriken Storm -> a finisher, Eviscerate and Black Powder both.
local SUB_AOE = "/castsequence reset=combat Shuriken Storm, Eviscerate, Shuriken Storm, Black Powder"
-- Deadlock guard (dummy log 2026-10-26): Secret Technique spends combo points outside the
-- sequence, so it can sit on Eviscerate at 0 combo points ("That ability requires combo
-- points") for the rest of the fight. A press gets ONE on-GCD attempt (a failed one
-- counts; off-GCD lines after it still run), so a builder line under the sequence would
-- never fire -- the builder is its own STEP, and a later press restores combo points.
local SUB_BUILD = "/cast [stealth][bonusbar:1] Shadowstrike; Backstab"
local SUB_AOE_BUILD = "/cast Shuriken Storm"
-- Shadow Dance has 2 charges: never start one inside another.
local SUB_DANCE = "/cast [nobonusbar:1] Shadow Dance"
-- Unholy San'layn cores (rev 1, see DEFAULTS["Unholy:San'layn"]). Base names only: the game
-- casts the morph (Scourge Strike -> Vampiric Strike, Death Coil -> Necrotic Coil, Epidemic
-- -> Graveyard, Festering Strike -> Festering Scythe). 1 Festering : 4 strikes : 4 spends,
-- the top players' ratio. Castsequences with the same text share one position.
local UHS_CORE = "/castsequence reset=combat Festering Strike, Scourge Strike, Death Coil, Scourge Strike, "
	.. "Death Coil, Scourge Strike, Death Coil, Scourge Strike, Death Coil"
local UHS_AOE = "/castsequence reset=combat Festering Strike, Scourge Strike, Epidemic, Scourge Strike, "
	.. "Death Coil, Scourge Strike, Epidemic, Scourge Strike, Death Coil"
-- Outbreak once per combat (top players: 0.2/min on a boss, ~0.9/min in M+ = once a pull);
-- the old reset=target re-cast it on every target swap (5.7-9.3/min in our own keys).
local UHS_OUTBREAK = "/castsequence reset=combat Outbreak, null"
-- Leads step 1 of every Unholy list: re-summons the ghoul when it's gone (despawned, died,
-- dismissed). [nopet] skips the line entirely while it's out, so no "dismiss your current
-- pet first" errors and no wasted press (v38 removed a bare Raise Dead for exactly that).
local UH_GHOUL = "/cast [nopet] Raise Dead"
-- Havoc Metamorphosis is a targeted leap: land on yourself so key 1 never needs a click.
local HAVOC_META = "/cast [@player] Metamorphosis"
local DEFAULTS = {
	-- WoW Forever Paladin, leveling 1-60 (no specs in Forever; keyed by class).
	-- Built from Forever leveling guides (Oct 2026). Forever changes
	-- that shape this: Judgement is OFF the GCD and NO LONGER CONSUMES the seal (debuffs
	-- last 40s), so the loop is: keep a Seal up, Judgement + Holy Strike on cooldown,
	-- Consecration for packs (full damage on 4 targets only). Spells you haven't
	-- learned yet just fail and fall through, so one list covers every level:
	-- Judgement 4, Holy Strike 6, Exorcism 20 (undead/demon only), Consecration 20,
	-- Hammer of Wrath 44 (target <20%).
	-- Seal upkeep: "/castsequence reset=28 Seal, null" casts the seal once, then sits
	-- on the dead "null" entry (casts nothing) until 28s pass -- re-seals just before
	-- the 30s seal expires instead of re-casting it every press (mana + GCD).
	-- Judgement goes FIRST: off-GCD, so it fires alongside the GCD spell below it.
	-- One step = priority mode either way (mash-safe). Swap the seal to Seal of Command
	-- in the editor once you talent it.
	["FOREVER_PALADIN"] = {
		mods = { alt = "Holy Light", ctrl = "Divine Protection" },
		st = {
			{ "Judgement", "/castsequence reset=28 Seal of Righteousness, null", "Hammer of Wrath", "Holy Strike", "Exorcism" },
		},
		aoe = {
			{ "Judgement", "/castsequence reset=28 Seal of Righteousness, null", "Consecration", "Holy Strike", "Hammer of Wrath" },
		},
	},
	-- Unholy DK. Built to match how the top Unholy DKs actually play it -- their cast
	-- profile is the spec
	-- in three numbers: Scourge Strike is the SPINE (135-207x), Death Coil/Necrotic
	-- Coil is the RP dump (~85x), Outbreak is cast ONCE (disease self-maintains).
	-- The OLD default buried Scourge Strike under 5 lone-CD steps that bounce, and led
	-- AoE step 9 with Outbreak (no CD -> fired every cycle = 32x disease re-apply).
	-- A live test showed exactly that: SS 30 (should be ~150), Death Coil 0, Outbreak
	-- 32. This fixes all three: ST filler is Scourge-first (-> Death Coil when rune-
	-- starved) with two Death-Coil-first steps to dump RP; AoE is Epidemic RP-dump +
	-- Scourge cleave. Outbreak is now ONLY the deepest fallback (fires when rune AND RP
	-- are both starved) so disease still recovers if it drops, without the spam. Lone
	-- CD steps (Soul Reaper x1 / Dark Transformation / Putrefy) bounce when down. Big
	-- CDs stay by-hand: Army [alt], Death Pact [ctrl]. NOTE: toggle to Single Target
	-- mode on bosses -- AoE mode on a single-target fight is why Death Coil was zero.
	["Unholy"] = {
		-- ctrl was Death Pact until 2026-10-17: the 12.1.5 Rider build drops it, so the
		-- held-Ctrl press now pops Icebound Fortitude (the big defensive) instead.
		mods = { alt = "Army of the Dead", ctrl = "Icebound Fortitude" },
		hero = "Rider of the Apocalypse",  -- what the rotation is built for (rotation check warns otherwise)
		rev = 1,   -- rev 1 (2026-10-28): step 1 re-summons a missing ghoul
		-- Priority mode (mash-friendly) fixed order, aligned to the Midnight rework:
		-- short-CD / no-cost abilities first so they fire on cooldown -- Dark Transformation
		-- (which RESETS Soul Reaper), then Soul Reaper, then Putrefy (feeds Soul Reaper).
		-- Then Festering Strike ABOVE Scourge Strike so Lesser Ghoul stacks actually get
		-- built (Festering is the engine now; that's the 0-Festering bug), Scourge Strike to
		-- spend stacks into ghouls, Death Coil to dump RP, Outbreak as disease insurance.
		-- A fixed order can't sense stack count, so it can't perfectly balance build-vs-spend
		-- -- for that, Sequence mode (which interleaves Festering/Scourge) may edge out
		-- Priority mode on Unholy specifically.
		priST  = { "Dark Transformation", "Soul Reaper", "Putrefy", "Festering Strike", "Scourge Strike", "Death Coil", "Outbreak" },
		priAOE = { "Dark Transformation", "Death and Decay", "Soul Reaper", "Putrefy", "Epidemic", "Festering Strike", "Scourge Strike", "Outbreak" },
		-- PASS 3 (2026-07-05, from a live log + SavedVariables read): the old default had
		-- LONE cooldown steps ({Soul Reaper}, {Dark Transformation}, {Putrefy}). Because
		-- the engine is a blind step-cycler, whenever one of those steps came up while the
		-- ability was on cooldown / rune-starved, the press cast NOTHING -- so Soul Reaper
		-- and Festering Strike showed literally 0 casts on a real kill. Fix: NO lone steps.
		-- Every step has a damage fallback so a press is never wasted; Soul Reaper leads
		-- (fires the instant it's up), Festering Strike gets two rune windows.
		-- v37 12.1 REBUILD (live dummy ST read 2026-08-12): Soul Reaper now consumes 3
		-- Lesser Ghoul stacks, but it fired only 1.3/min because Scourge Strike (13.6/min)
		-- ate stacks faster than Festering (2.6/min) built them. 12.1 REVERSES PASS 3.5's
		-- anti-over-build logic: with Soul Reaper as a SECOND stack sink, build MORE.
		-- Festering now leads 4 steps; Soul Reaper gets 2 windows, each followed by a
		-- Festering refeed. Putrefy (top dmg, 18%) kept high. Every step ends in a damage
		-- fallback so no press is wasted. A/B target to beat: ~27.6k total dummy DPS.
		st = {
			-- v50/v51 TRIED + REVERTED (2026-10-22/23): Runic Power sat >=90 for 82% of a
			-- single-dummy run, so v50/v51 gave Death Coil lead steps to spend it. RP cap was
			-- fixed, but DPS FELL: v50 (DC in front of Festering) 32.0k, v51 (DC on its own
			-- extra steps) 36.0k vs v47's 40.8k. Extra coils gained ~150k, but Putrefy (same 5
			-- casts) hit a third weaker and disease damage fell ~30% -- both scale with Lesser
			-- Ghouls, and pushing Festering later in the cycle cost more than capped RP does.
			-- Lesson: capped RP is cheap here; don't trade Festering/ghoul timing for it.
			{ UH_GHOUL, "Soul Reaper", "Festering Strike", "Scourge Strike", "Death Coil" },
			{ "Festering Strike", "Scourge Strike", "Death Coil" },
			{ "Putrefy", "Scourge Strike", "Death Coil" },
			{ "Dark Transformation", "Scourge Strike", "Death Coil" },
			{ "Soul Reaper", "Festering Strike", "Scourge Strike", "Death Coil" },
			{ "Festering Strike", "Scourge Strike", "Death Coil" },
			-- v47 (2026-10-22, live 95s single-dummy log): same two leaks as AoE had --
			-- Putrefy (top dmg, 18.9%) had ONE slot and sat ready for a 33s gap, so it now
			-- also leads steps 7 and 9 (it has a CD, so it can't spam); and Outbreak re-cast
			-- 5x where 1 kept the plague up, so it's a seed-once castsequence like AoE's.
			{ "Putrefy", "Scourge Strike", "Death Coil" },
			{ "Death Coil", "Scourge Strike" },
			{ "Putrefy", "Scourge Strike", "Death Coil" },
			-- Raise Dead REMOVED from the loop (v38): the Unholy ghoul is permanent, so
			-- re-casting it spammed "must dismiss your current pet first" errors + wasted
			-- the press. Summon it once manually; the loop just refreshes disease here.
			{ "/castsequence reset=target/combat Outbreak, null", "Scourge Strike", "Death Coil" },
		},
		-- PASS 4 (2026-07-16, from the player's OWN M+ log): AoE ramped terribly on
		-- fresh packs (74k) and only hit 241k on long pulls -- because Outbreak
		-- (the ONLY source of Virulent Plague, which Epidemic's whole damage scales
		-- off) was buried at step 10, so Epidemic hit undiseased mobs for ~10 GCDs
		-- every pull. Outbreak now SEEDS at step 2, so diseases are up by GCD ~2 and
		-- Epidemic/DnD ramp instantly; it re-fires once per loop (~periodic, NOT the
		-- old spam). USE SEQUENCE MODE FOR AOE -- Priority mode structurally can't do
		-- this (a no-CD Outbreak high in the priority list spams; low = the ramp bug).
		aoe = {
			{ UH_GHOUL, "Death and Decay", "Scourge Strike", "Epidemic" }, -- drop the zone
			-- v44 (2026-10-22, live 98s/3-target log): Outbreak has no CD, so leading this
			-- step with it re-cast it every loop -- 8.6/min (~1 in 7 GCDs) re-applying a
			-- plague that was already up. The castsequence seeds it on the first press of a
			-- pull, then sits on "null" (never castable) so the step falls through to
			-- Scourge/Epidemic.
			-- A/B (v45): 41.3k (old, WITH oil+potion) -> 43.9k (new, clean); Scourge 6.1 ->
			-- 15.3/min, disease share unchanged (~20%) on ONE Outbreak per pull. A timed reset
			-- (=15) never fires because every press restarts the timer, so reset=target re-seeds
			-- when you move to a new mob (chain pulls) and reset=combat on the next pull.
			{ "/castsequence reset=target/combat Outbreak, null", "Scourge Strike", "Epidemic" }, -- SEED Virulent Plague once per target/pull
			{ "Festering Strike", "Scourge Strike", "Epidemic" },
			-- v46: Putrefy (top single hitter) had ONE slot in 10, so it sat ready for up to
			-- 42s waiting for its step (3 casts vs 5 in an identical run, 12.8% vs 15.9% dmg).
			-- It now leads steps 4/6/9; it has a cooldown, so it can't spam -- when it's down
			-- these steps fall through to Epidemic/Scourge exactly as before.
			{ "Putrefy", "Epidemic", "Scourge Strike" },
			{ "Dark Transformation", "Scourge Strike", "Epidemic" },
			{ "Putrefy", "Epidemic", "Scourge Strike" },
			{ "Soul Reaper", "Scourge Strike", "Epidemic" },
			-- v50 gave Epidemic extra lead steps to spend capped RP (69% of the AoE run);
			-- reverted untested in v52 after the same idea cost 12% single-target (see st).
			{ "Scourge Strike", "Epidemic" },
			{ "Putrefy", "Scourge Strike", "Epidemic" },
			{ "Epidemic", "Scourge Strike" },
		},
	},
	-- Unholy, San'layn hero tree (rev 1, 2026-10-28). Picked over the plain "Unholy" (Rider)
	-- entry whenever San'layn is the active hero tree. Built from the top San'layn DKs' casts
	-- (San'layn players only: Mythic Sszorak, Altar of Fangs + Murder Row keys). Per minute:
	--   raid boss: strikes 23.6, coils 22.1, Festering 6.4, Putrefy 3.4, Soul Reaper 2.3,
	--              Dark Transformation + Blightfall 2.8, Outbreak 0.2, Army 0.8
	--   M+:        strikes ~20, Epidemic/Graveyard ~9.6, coils ~9, Festering 5.9, Putrefy 3.8,
	--              Soul Reaper 1.9, DT + Blightfall 2.3, Death and Decay 1.4, Outbreak 0.9
	-- No top player ran Rider in either (0 of 24); San'layn also sims +4.5% ST / +12% at 5
	-- targets on our test gear. Goal: match top players; the player adjusts on their own keys.
	-- Mash-safe (one on-GCD try per press): the ratio lives in a castsequence (moves on only
	-- when a cast lands). Cooldowns own steps, 2x per cycle (a step whose spell isn't ready
	-- costs one press); Dark Transformation's second step casts Blightfall. A lone strike
	-- step un-sticks the core when it waits on a coil with no Runic Power; a lone spend
	-- spends when it waits on runes. Outbreak steps fall through to a spend once it's out.
	-- Army of the Dead and trinkets stay on the player's own keys: no modifiers.
	["Unholy:San'layn"] = {
		mods = {},
		hero = "San'layn",
		-- rev 4 (AoE): the 3-dummy run cast Festering + Scythe 1.9/min vs the top's ~6 (the core
		-- stalls on Epidemic waiting for RP, so its one Festering rarely comes up). Own steps
		-- fix it: 3 dummies, pets included, 95.8K (rev 2) -> 118.6K (rev 3, 2 steps, 13/min)
		-- -> 117.2K (rev 4, 1 step, 10.6/min). Same damage, and rev 4's cast mix sits closest
		-- to the top players' (Vampiric 12.8, Epidemic 5.8, Graveyard 4.8, Putrefy 3.8/min).
		-- Death and Decay sits on the second Outbreak step, which only falls through to it once
		-- Outbreak is out (1.7/min vs the top's ~1.3; its own step cast it 2.4).
		-- rev 2: step 1 re-summons a missing ghoul.
		rev = 4,
		st = {
			{ UH_GHOUL, UHS_CORE },
			{ "Putrefy", "Scourge Strike" },
			{ UHS_CORE },
			{ UHS_OUTBREAK, "Death Coil" },
			{ UHS_CORE },
			{ "Dark Transformation", "Scourge Strike" },
			{ UHS_CORE },
			{ "Soul Reaper", "Scourge Strike" },
			{ UHS_CORE },
			{ "Putrefy", "Scourge Strike" },
			{ UHS_CORE },
			{ UHS_OUTBREAK, "Death Coil" },
			{ UHS_CORE },
			{ "Scourge Strike" },
			{ UHS_CORE },
			{ "Dark Transformation", "Scourge Strike" },
			{ "Soul Reaper", "Scourge Strike" },
		},
		aoe = {
			{ UH_GHOUL, UHS_AOE },
			{ UHS_OUTBREAK, "Scourge Strike" },
			{ UHS_AOE },
			{ "Putrefy", "Scourge Strike" },
			{ UHS_AOE },
			{ "Scourge Strike" },
			{ UHS_AOE },
			{ "Dark Transformation", "Scourge Strike" },
			{ UHS_AOE },
			{ UHS_OUTBREAK, "Death and Decay" },
			{ UHS_AOE },
			{ "Soul Reaper", "Scourge Strike" },
			{ UHS_AOE },
			{ "Putrefy", "Scourge Strike" },
			{ "Epidemic" },
			{ "Dark Transformation", "Scourge Strike" },
			{ "Festering Strike" },
		},
	},
	-- Shadow Priest (Voidweaver, LEVELING build). Tuned 2026-07-09 from the player's OWN
	-- follower-dungeon combat log: Voidweaver confirmed (Void Torrent -> Void
	-- Blast in the log). The log exposed the big leak -- Voidform / Power Infusion were at
	-- ZERO casts (weren't pressing the CD keys), which is most of the missing damage AND
	-- why AoE felt weak (Voidform -> Void Volley IS the cleave). So those CDs are now
	-- WOVEN INTO the button to auto-fire on cooldown. Shadowfiend is NOT a step -- as
	-- Voidweaver it auto-summons as Voidwraith off Voidform/the rift (log: 26 Voidwraith
	-- summons, 0 manual Shadowfiend casts), so a manual cast would be dead. Spine = Mind Blast
	-- (-> Void Blast under Entropic Rift) + Shadow Word: Madness + Mind Flay; Void Torrent
	-- keeps the Rift up; Tentacle Slam spreads Vampiric Touch (the AoE engine, cleaved via
	-- Psychic Link); Vampiric Touch is the ONLY hardcast DoT -- Misery applies SW:Pain
	-- with it for free and Tentacle Slam refreshes both (97% uptime verified live on a
	-- +2), so manual SW:Pain is CUT as redundant. SW:Death is OFF the loop (self-damage +
	-- off-window when blind-cast) -> bind it to your own key for execute windows. Halo removed
	-- (it's an ARCHON ability -- re-add if this char goes Archon for raiding at 90). EVERY
	-- step ends in Mind Flay (always-castable) so no press is wasted + it backstops any
	-- proc-name. Dispersion is the only held modifier [shift]; Silence/Fade stay own keys.
	["Shadow"] = {
		mods = {},  -- no held modifiers: player wants a clean 1 + 2-6 + shift1-6 bar; CDs are woven into the button, Dispersion goes on a normal key
		channelGuard = true,  -- [nochanneling] so a spam-press can't clip Mind Flay / Void Torrent (hardcasts still need cadence)
		hero = "Voidweaver",  -- what the rotation is built for (rotation check warns otherwise)
		-- rev 1 (2026-10-28): Voidform leads 4 ST steps instead of 1. Paced at ~1.26 s a press,
		-- the lone Voidform step always followed the Mind Flay-lead step, so it landed mid-channel,
		-- the channel guard skipped it, and the cycle repeated: Voidform went unpressed for 3 minutes
		-- after coming off cooldown (0-2 casts in 5-minute dummy runs vs 3 possible). On cooldown it
		-- falls through to the rest of the step, so the extra copies cost nothing.
		rev = 1,
		priST  = { "Voidform", "Void Volley", "Power Infusion", "Mind Blast", "Void Torrent", "Tentacle Slam", "Vampiric Touch", "Shadow Word: Madness", "Mind Flay" },
		priAOE = { "Voidform", "Tentacle Slam", "Power Infusion", "Void Torrent", "Void Volley", "Mind Blast", "Vampiric Touch", "Shadow Word: Madness", "Mind Flay" },
		-- EXP4 2026-07-17: the step-cycler advances every PRESS, so with fast
		-- mashing Mind Flay (buried last in every step) never lands off-GCD (0/30
		-- on a dummy). Fix: INTERLEAVE dedicated Mind-Flay-lead steps (every ~3rd
		-- step) so a mash keeps hitting one and the filler actually fires in the
		-- gaps. Mind Flay has no CD, so on a Mind-Flay-lead step it casts whenever
		-- you're off-GCD. High-value steps (Tentacle Slam x2, Void Torrent, Void
		-- Volley, Mind Blast) still lead the other slots. (Also carries EXP2: TS
		-- to 2 steps + Void Volley.) A/B on a dummy vs the flat step list.
		-- EXP5 2026-07-18: EXP4's 4 Mind-Flay-lead steps over-corrected under paced
		-- tapping (Mind Flay hit target 8.6/min but starved Mind Blast 2.9 vs 5.6
		-- and SW:Madness 3.3 vs ~10). Pulled to 2 Mind-Flay leads; generators/
		-- spender lead the rest and Mind Flay is still the fallback everywhere, so
		-- it fills only the true gaps.
		-- v27 2026-07-18: SIM-DERIVED. Built a calibrated Go simulator (scratchpad/vsim)
		-- that reproduces BOTH real dummy runs from their profiles (v24 34.5k, v25 22.7k)
		-- using per-cast values pulled from a real Shadow log (direct + passive-engine
		-- share; Mind Blast/SW:Madness/Void Torrent/Voidform/Tentacle each drive ~46k of
		-- proc/rift damage, Mind Flay & SW:Pain drive ~0). Search over orderings @1240ms
		-- returned ~37.7k (+9%): the lever is MAXING SW:Madness (your 98k-value cast:
        -- 9.7/min vs v24's 6.7), Mind Blast on CD, Mind Flay as FILLER (35k >> SW:Pain's
		-- 5k), and DROP SW:Pain entirely (dead weight). So: Mind Blast leads fall to
		-- SW:Madness (double-dip the spender), SW:Madness leads with Mind Flay filler,
		-- real CDs (Void Torrent/Tentacle/Void Volley/Voidform/PI) kept though the sim
		-- under-values them (didn't model PI haste / VT Insanity). ⚠ Press at ~1240-1280ms
		-- NOT 1100 (GCD floor 1240 -- faster wastes half the presses in-GCD + scrambles
		-- the order). Test vs 34.5k. [[voidseq-shadow-press-rate-diagnosis]]
		-- v36 2026-07-19: made ST consistent with AoE -- close EVERY line with a
		-- Mind Flay fallback so no line can dead-press. The 5 { CD-cast, SW:Madness }
		-- lines (Mind Blast x4, Void Volley x1) previously whiffed when the lead was
		-- on CD AND Insanity was empty; now they fall through to Mind Flay. Safe
		-- because Mind Flay = Void Blast (INSTANT ~30k) during Entropic Rift and real
		-- damage outside it -- not a pure channel-block. Baseline to beat: v29 = 35.7k
		-- on the in-game meter. If this holds or beats it, keep; if it drops, revert to
		-- the v29 backup. [[voidseq-shadow-dps-verdict-2026-07-18]]
		-- v39 12.1: Void Volley is now 3 CHARGES per Voidform (5 w/ Improved Voidform),
		-- not a cooldown. Live dummy read: Voidform entered ~0.6/min and Void Volley
		-- fired only 1x -- charges left undumped. Spread Void Volley across 3 steps (2,6,9)
		-- so a Voidform window cycles through and dumps its charges; each falls through to
		-- Mind Blast/SW:Madness/Mind Flay when out of Voidform (no charges = unavailable).
		-- SW:Madness stays maxed (now also stacks haste + extends Voidform). Beat ~34.4k.
		st = {
			{ "Voidform", "Mind Flay" },
			{ "Void Volley", "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			{ "Shadow Word: Madness", "Mind Flay" },
			{ "Void Torrent", "Mind Flay" },
			{ "Voidform", "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			{ "Void Volley", "Shadow Word: Madness", "Mind Flay" },
			{ "Tentacle Slam", "Mind Flay" },
			{ "Voidform", "Shadow Word: Madness", "Mind Flay" },
			{ "Void Volley", "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			{ "Shadow Word: Madness", "Mind Flay" },
			{ "Power Infusion", "Mind Flay" },
			{ "Voidform", "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			{ "Shadow Word: Madness", "Mind Flay" },
			{ "Mind Flay", "Shadow Word: Madness" },
		},
		-- AoE REBUILT 2026-07-18 (user caught it: we tuned ST all session, never AoE --
		-- and you're in AoE mode ~90% of a dungeon). Old list LED with Mind Flay (a
		-- single-target CHANNEL = worst AoE button) 3x and under-used SW:Madness. Same
		-- lesson as ST: Mind Flay is a trap, max the spender. Voidweaver AoE = spread
		-- DoTs (Tentacle Slam) so every nuke cleaves via Psychic Link, then SW:Madness
		-- / Mind Blast / Void Torrent / Void Volley (all cleave). Mind Flay = fallback
		-- ONLY (never leads). Test in a KEY / multi-dummy -- a single dummy can't show AoE.
		-- v43 2026-10-16 (12.1.5 audit): AoE had ONE Void Volley step in 12, so a Voidform's
		-- 3 charges (Ancient Madness build) went mostly unspent -- the same leak v39 fixed in
		-- ST. Void Volley now leads steps 6/8/10; out of Voidform each falls through to
		-- SW:Madness/Mind Blast/Mind Flay. 12.1.5 had no Shadow changes; build = a
		-- Voidweaver AoE build without the S2 4pc.
		aoe = {
			{ "Voidform", "Tentacle Slam", "Mind Flay" },
			{ "Tentacle Slam", "Shadow Word: Madness", "Mind Flay" },
			{ "Void Torrent", "Shadow Word: Madness", "Mind Flay" },
			{ "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			-- v48 (2026-10-22, two live 4-dummy AoE logs): Mind Flay fired ZERO times and the
			-- player sat idle ~3-4s at a time (~25-30% of the fight). Cause: when SW:Madness
			-- fails for "Not enough insanity" the game counts that as the press's one cast
			-- attempt, so the Mind Flay line after it never runs (21x in one run). A cooldown
			-- failure falls through; a RESOURCE failure does not. So two steps now LEAD with
			-- Mind Flay (as ST already does) to fill the Insanity-starved gaps; SW:Madness
			-- still leads/backs 7 other steps.
			-- v49: a blocked press (channel guard) still ADVANCES the step, so the lone Power
			-- Infusion step kept landing mid-channel and PI never fired (0 attempts in 37s).
			-- PI / Voidform now also front the two Mind Flay steps -- a COOLDOWN failure falls
			-- through, so when they are down these steps still channel Mind Flay.
			{ "Power Infusion", "Mind Flay", "Shadow Word: Madness" },
			{ "Shadow Word: Madness", "Tentacle Slam", "Mind Flay" },
			{ "Void Volley", "Shadow Word: Madness", "Mind Flay" },
			{ "Tentacle Slam", "Mind Blast", "Mind Flay" },
			{ "Void Volley", "Shadow Word: Madness", "Mind Blast", "Mind Flay" },
			{ "Voidform", "Mind Flay", "Shadow Word: Madness" },
			{ "Power Infusion", "Shadow Word: Madness", "Mind Flay" },
			{ "Void Volley", "Mind Blast", "Shadow Word: Madness", "Mind Flay" },
			{ "Tentacle Slam", "Shadow Word: Madness", "Mind Flay" },
			{ "Shadow Word: Madness", "Mind Flay" },
		},
	},
	-- Guardian Druid (tank). Built to match how the top M+ Guardian bears actually
	-- play -- their real cast breakdown. MOONFIRE-SPAM + LUNAR BEAM build (Galactic
	-- Guardian fires Moonfire off-GCD, the #1 cast at ~26/min). Key finding: the top
	-- M+ bear
	-- DOES run Sundering Roar (snap threat, ~on CD) AND Incarnation on CD (not
	-- saved) — so BOTH are now lone steps in the auto-loop (bounce when on CD). He
	-- casts NO Swipe (Moonfire covers AoE), so Ironfur falls through to Moonfire
	-- everywhere. Weights matched: Moonfire >> Ironfur (rage dump) > Thrash (high
	-- uptime) > Lunar Beam > Mangle; Barkskin rolls on CD in-loop. Reactive
	-- defensives stay by-hand: ALT -> Frenzied Regen (heal), SHIFT -> Survival
	-- Instincts (big DR). Skull Bash (kick) + Growl (taunt) stay your own keys.
	["Guardian"] = {
		-- rev 1 (2026-10-27): no held modifiers (keys 1-7 + Shift only); Frenzied Regeneration
		-- and Survival Instincts go on Naga keys via VoidBars Suggest instead of Alt / Shift.
		rev = 1,
		mods = {},
		-- PASS 2 (2026-07-02, tuned off a live +6 Windrunner Spire): pass 1 got the
		-- abilities IN (Sundering Roar + Incarnation confirmed firing at the top bear's
		-- rate) but Thrash landed at HALF his rate (8 vs 16/min) and Lunar Beam/
		-- Ironfur were starved — Moonfire (off-GCD via Galactic Guardian) hogged the
		-- lone-step cycle. Fix: priority-STACK every step so the high-value ability
		-- fires the instant it's ready and Moonfire only fills the gap (no dead
		-- presses). Thrash appears in almost every step -> it fires on every CD;
		-- Ironfur-first steps still dump rage; Lunar Beam gets two shots.
		-- v40 12.1: added MAUL as a rage DAMAGE/threat spender. Live baseline showed rage
		-- dumped 100% into Ironfur (10/min), Maul never cast -- leaving threat on the table.
		-- 12.1 buffed this: Gory Fur (Ironfur -> free Maul & vice-versa), Wild Guardian
		-- (Maul +Nature dmg), all dmg +8%. Ironfur still LEADS its steps (mitigation priority
		-- for real tanking); Maul follows (Gory-Fur-free) + gets 2 dedicated steps. Every
		-- step ends in Moonfire (off-GCD filler) so no dead press. Threat proxy = damage.
		-- 12.1: MAUL EXPERIMENT REVERTED (v40/v41). This character is an ASTRAL build
		-- (Elune's Chosen — damage from Moonfire/Lunar Beam/Starsurge/Thrash, NOT rage
		-- spenders). Maul is not in the build; it fired 0x even when leading. Back to the
		-- proven rage->Ironfur + Astral-fill rotation. If the user ever specs a rage-spender
		-- (Druid of the Claw) build, re-add Maul then.
		st = {
			{ "Sundering Roar", "Thrash", "Moonfire" },
			{ "Mangle", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Ironfur", "Moonfire" },
			{ "Lunar Beam", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Ironfur", "Moonfire" },
			{ "Mangle", "Moonfire" },
			{ "Incarnation: Guardian of Ursoc", "Thrash", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Barkskin", "Moonfire" },
			{ "Ironfur", "Moonfire" },
		},
		aoe = {
			{ "Sundering Roar", "Thrash", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Ironfur", "Moonfire" },
			{ "Lunar Beam", "Thrash", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Ironfur", "Moonfire" },
			{ "Mangle", "Thrash", "Moonfire" },
			{ "Incarnation: Guardian of Ursoc", "Thrash", "Moonfire" },
			{ "Lunar Beam", "Thrash", "Moonfire" },
			{ "Ironfur", "Moonfire" },
			{ "Thrash", "Moonfire" },
			{ "Barkskin", "Moonfire" },
		},
	},
	-- Havoc DH (DPS). Built 2026-06-15 for LEVELING (char is L80 climbing to 90),
	-- so it's the CORE kit available now, NOT a max-level end-game build. Untalented/
	-- unlearned abilities (Essence Break, Felblade, Glaive Tempest) just bounce
	-- until you pick them up. Cooldowns (Immolation Aura, Eye Beam) are lone steps;
	-- spenders (Chaos Strike / Blade Dance) fall through to Demon's Bite when
	-- Fury-starved. Metamorphosis (burst) on ALT, Blur (defensive) on CTRL — never
	-- auto. Re-do the full top-player analysis at level 90, like the DK.
	-- rev 1 (2026-10-29, level-81 Fel-Scarred dummy run vs a top Fel-Scarred Mythic kill):
	-- the old lists never cast Blade Dance (top: Blade Dance + Death Sweep 10.5/min), The Hunt
	-- (0.9/min) or Metamorphosis (0.5/min, Alt only, and the player uses no modifiers), and
	-- overused Felblade (9.6/min vs 3.0). Demon's Bite does nothing with Demon Blades talented.
	-- rev 2 (same night, rev 1 tested 10 min on the dummy): a step whose first spell is on
	-- cooldown ("Not yet recovered") ENDS the press, so nothing after it in that step ever
	-- casts (Chaos Strike: 0 casts in 10 min, though in melee range 98% of the time). One spell
	-- per step now: Chaos Strike every other step (always castable with Fury), each cooldown
	-- on its own step. A step that isn't ready costs one 250 ms press, not a GCD.
	-- (Throw Glaive shows ~28 casts/min in the log with or without a step: a talent fires it.)
	-- rev 3: rev 2 cast Blade Dance + Death Sweep 5.1/min (top 10.5) and Eye Beam 1.3 (top 2.4)
	-- but Felblade 6.8 (top 3.0) with 287 "Not enough fury" Chaos Strike presses. Blade Dance
	-- and Eye Beam get more steps; Felblade sits after Chaos Strike so it only builds once
	-- Fury runs dry.
	-- rev 4 (2026-10-29, full talent build, 7,599 on the middle dummy with rev 3): Essence
	-- Break is talented but rev 3 never cast it (top raid Havoc: 1.9/min, ~6% of damage).
	-- It follows each Eye Beam, and Eye Beam follows Metamorphosis (Chaotic Transformation
	-- resets Eye Beam and Blade Dance on Meta).
	-- rev 5 (2026-10-29, rev 4 = 8,119 middle dummy): chosen offline by voidsim's havocsim, a
	-- rotation model fitted on the rev 4 log (it predicted the rev 3 run within 1%). Eye Beam
	-- gets four steps: its press often lands on the GCD and misses, and every Eye Beam is a
	-- Demonic Metamorphosis (more Annihilation / Death Sweep). Meta and The Hunt are listed
	-- twice only for more chances; their cooldowns still gate them. Predicted 8,650.
	["Havoc"] = {
		mods = {},
		rev = 5,
		-- Recommended builds, generated by the talent-pull tool from current top raid
		-- players' active loadouts (Fel-Scarred is the dominant Havoc hero right now).
		builds = {
			{ name = "Fel-Scarred (Raid)", build = "CEkAG5bbocFKcv+yIq8fPd6ORZmZmZmZ2mxMzMGzkxMDAAAAAAYWMmtZYmBmx2sNzMjxALDsNbmxwsopxMzYGbAAAADAABAzMYAIAAwA" },
			{ name = "Aldrachi Reaver (Raid)", build = "CEkAG5bbocFKcv+yIq8fPd6ORZGMzMz2MmZmxMzEmZAAAAAAAzyDMGzwMzsNzMzysNPwMWGMjtZWmZZWmZmZZb2mmmxMjZsAAAAAAgAMzMzgBgAAAD" },
		},
		st = {
			{ HAVOC_META },
			{ "Felblade" },
			{ "Eye Beam" },
			{ "Essence Break" },
			{ "Eye Beam" },
			{ "Blade Dance" },
			{ "Chaos Strike" },
			{ HAVOC_META },
			{ "Eye Beam" },
			{ "The Hunt" },
			{ "Blade Dance" },
			{ "Immolation Aura" },
			{ "Immolation Aura" },
			{ "Chaos Strike" },
			{ "The Hunt" },
			{ "Eye Beam" },
			{ "Blade Dance" },
			{ "Chaos Strike" },
			{ "Felblade" },
		},
		aoe = {
			{ "Blade Dance" },
			{ "Chaos Strike" },
			{ "Eye Beam" },
			{ "Essence Break" },
			{ "Blade Dance" },
			{ "Immolation Aura" },
			{ "Chaos Strike" },
			{ "Blade Dance" },
			{ HAVOC_META },
			{ "Glaive Tempest" },
			{ "Blade Dance" },
			{ "Chaos Strike" },
			{ "The Hunt" },
			{ "Blade Dance" },
			{ "Felblade" },
		},
	},
	-- Devourer: no hand-tuned list; the generated per-hero-tree rotations (Rotations.lua) load.
	-- Windwalker Monk (DPS). The first version was an unverified Shado-Pan leveling draft
	-- (multi-spell steps, Alt/Ctrl cooldowns); rev 1 below replaces it.
	-- rev 1 (2026-10-29, level-81 Conduit of the Celestials, from the top 5 Mythic Nek'zali
	-- Windwalkers' casts: Tiger Palm 10.7/min, Spinning Crane Kick 9.0, Rising Sun
	-- Kick 8.0, Fists of Fury 7.3, Blackout Kick 5.9, Whirling Dragon Punch 2.5, Rushing Wind
	-- Kick 2.5, Zenith 1.0, Xuen 0.7). One spell per step: a step whose first spell isn't
	-- ready ends the press, so multi-spell steps starve everything behind them (Havoc lesson).
	-- Xuen and Zenith are woven into key 1 (no Alt/Ctrl). Combo Strikes: the same spell is
	-- never in two steps in a row, and fillers (Tiger Palm / Blackout Kick / Spinning Crane
	-- Kick) sit at least two steps apart, so a failed step between them can't make a repeat.
	-- Left out: Touch of Death (needs a low-health target), Expel Harm and Flying Serpent Kick
	-- (top players don't use them for damage), Strike of the Windlord / Storm, Earth, and Fire
	-- (not in the current build). Celestial Conduit unlocks later (hero tree); add it then.
	["Windwalker"] = {
		mods = {},
		rev = 1,
		st = {
			{ "Invoke Xuen, the White Tiger" },
			{ "Tiger Palm" },
			{ "Zenith" },
			{ "Fists of Fury" },
			{ "Rising Sun Kick" },
			{ "Spinning Crane Kick" },
			{ "Whirling Dragon Punch" },
			{ "Tiger Palm" },
			{ "Fists of Fury" },
			{ "Rising Sun Kick" },
			{ "Blackout Kick" },
			{ "Spinning Crane Kick" },
			{ "Rushing Wind Kick" },
			{ "Tiger Palm" },
			{ "Rising Sun Kick" },
			{ "Fists of Fury" },
			{ "Blackout Kick" },
			{ "Spinning Crane Kick" },
		},
		aoe = {
			{ "Invoke Xuen, the White Tiger" },
			{ "Spinning Crane Kick" },
			{ "Zenith" },
			{ "Fists of Fury" },
			{ "Tiger Palm" },
			{ "Whirling Dragon Punch" },
			{ "Spinning Crane Kick" },
			{ "Rising Sun Kick" },
			{ "Tiger Palm" },
			{ "Fists of Fury" },
			{ "Spinning Crane Kick" },
			{ "Rushing Wind Kick" },
			{ "Blackout Kick" },
			{ "Spinning Crane Kick" },
			{ "Tiger Palm" },
		},
	},
	-- Beast Mastery Hunter (DPS). Pack Leader with the "Pack Leader (M+)" build from Builds.lua.
	-- rev 2 (2026-10-29): single target from the top 3 Mythic BM players' casts on a
	-- single-target raid boss (per minute): Kill Command 18.0, Cobra Shot 15.6, Barbed Shot
	-- 10.5, Bestial Wrath 2.0, Wild Thrash 1.8. Rev 1's level-80 dummy run cast Wild Thrash
	-- 4.0/min, so it's out of the ST list; its global cooldowns go to Kill Command / Barbed Shot
	-- (15.0 and 8.5/min in that run). AoE (rev 1) follows Mythic+ trash casts: Wild Thrash
	-- is the AoE button (no Multi-Shot). One spell per step (a step whose spell isn't ready
	-- just ends that press). Dire Beast casts itself from talents; Kill Shot / Multi-Shot unused.
	["Beast Mastery"] = {
		mods = {},
		rev = 2,
		st = {
			{ "Bestial Wrath" },
			{ "Barbed Shot" },
			{ "Kill Command" },
			{ "Cobra Shot" },
			{ "Kill Command" },
			{ "Barbed Shot" },
			{ "Kill Command" },
			{ "Cobra Shot" },
			{ "Kill Command" },
			{ "Barbed Shot" },
			{ "Cobra Shot" },
			{ "Kill Command" },
			{ "Cobra Shot" },
		},
		aoe = {
			{ "Bestial Wrath" },
			{ "Wild Thrash" },
			{ "Barbed Shot" },
			{ "Kill Command" },
			{ "Wild Thrash" },
			{ "Cobra Shot" },
			{ "Kill Command" },
			{ "Barbed Shot" },
			{ "Wild Thrash" },
			{ "Kill Command" },
			{ "Cobra Shot" },
		},
	},
	-- Restoration Druid (Keeper of the Grove) HEALER. Built to match a top M+ Keeper's
	-- casts. HEAL-ONLY: the cat/moonkin DPS
	-- weave that even Keepers do is intentionally stripped. The whole profile heals
	-- whoever you HOVER (a VuhDo / raid-frame box) -- the heal spells carry an
	-- [@mouseover,help] conditional (see CONDITIONALS), so each press casts on the
	-- box under your cursor (falls to your target, then self). ST = spot-heal cycle
	-- (Rejuvenation spine + Swiftmend/Regrowth); AoE = group ramp (Wild Growth + Rejuv
	-- spread). Big cooldowns are by-hand: ALT -> Tranquility (raid save), CTRL ->
	-- Ironbark (external on the hovered box), SHIFT -> Convoke. NOTE: the macro picks
	-- the SPELL, your cursor picks WHO -- it can't triage HP, so it blankets HoTs and
	-- spot-heals. A learning/throughput tool; pair with VuhDo/Cell for the frames.
	-- rev 2 (2026-10-27): rebuilt from the top 3 Mythic Resto druids' casts (Ula'tek,
	-- Entombed Sentinels) + 12.1.5 guides. Swiftmend on cooldown (~12s) then Regrowth
	-- (Soul of the Forest), Regrowth chains under Abundance (5 Rejuvenations out),
	-- Rejuvenation recast = Germination, Wild Growth often, Starsurge/Wrath/Moonfire when
	-- nothing needs a heal. Lifebloom is NOT here: it lives on key 2 ("VS Lifebloom",
	-- auto-aimed at the group's tank), with Ironbark / Nature's Cure / Rebirth macros
	-- (HEAL_MACROS). No held modifiers (keys 1-7 + Shift only): Tranquility, Convoke,
	-- Nature's Swiftness go on keys. Efflorescence places itself (Lifetreading).
	-- WHO: hover a friendly frame -> heals them; target/hover an enemy (and no friendly
	-- hovered) -> damage; neither -> heals you (healSelfLast). channelGuard: a press
	-- during Tranquility / Convoke waits instead of clipping it.
	["Restoration"] = {
		class = "DRUID",   -- spec names collide: a Restoration Shaman must not load this
		rev = 4,
		mods = {},
		channelGuard = true,
		healSelfLast = true,
		-- rev 3 (2026-10-27): ONE loop, no ST/AoE switch (the player: "healers should always be
		-- in AoE healing mode"). Who you hover is the only choice: spot heals land on them while
		-- the loop keeps Rejuvenation spread over the group and Wild Growth going. Ratio per
		-- 16 presses ~ the top logs: 7 Rejuvenation, 5 Regrowth, 2 Swiftmend, 2 Wild Growth.
		oneMode = true,
		cond = {
			["Rejuvenation"] = HEAL_HOVER, ["Regrowth"] = HEAL_HOVER, ["Swiftmend"] = HEAL_HOVER,
			["Wild Growth"] = HEAL_HOVER,
			["Starsurge"] = DMG_HOVER, ["Wrath"] = DMG_HOVER, ["Moonfire"] = DMG_HOVER,
		},
		st = RESTO_LOOP,
		aoe = RESTO_LOOP,
		-- In Cat Form (bonusbar 1; 2 = prowling) key 1 runs the cat weave instead, unless
		-- you hover a friendly frame: then it heals them, which drops you out of cat.
		formLoop = {
			rule = "[bonusbar:1/2,@mouseover,help,nodead] heal; [bonusbar:1/2] form",
			seq = { { RESTO_CAT } },
		},
	},
	-- ===== ROGUE -- leveling basics. Level-agnostic: abilities you haven't
	-- learned yet (Mutilate/Envenom, Dispatch/Between the Eyes, Backstab,
	-- Shuriken Storm, etc.) simply bounce until you pick them up, so this
	-- auto-upgrades as you level. At ~10 the button effectively runs the spec
	-- builder -> Eviscerate + Slice and Dice. Every step falls through to a
	-- guaranteed attack (no dead presses). No held modifiers (the player uses only
	-- 1-7 + Shift 1-7, 2026-10-23): each spec's damage cooldown is woven in as a step lead
	-- (off-GCD ones fire alongside the next line); Evasion/Vanish go on keys. NOTE: a
	-- finisher fires at ANY combo point (it only fails at 0), so spending is paced by step
	-- order -- builders between finishers. Outlaw is paced (rev 2: 4 builders -> finisher);
	-- Assassination/Subtlety still spend early and need the same pass. AoE leads with the
	-- spec's multi-target ability. =====
	-- Assassination / Subtlety rev 1 (2026-10-24): same design as Outlaw rev 4 (see there and
	-- memory wow-macro-ongcd-fail-blocks). The old steps paced combo points by step order and
	-- put a cooldown in front of each filler, which a mashing player breaks (phase-lock) and a
	-- failed on-GCD cooldown blocks. Now every other step is a castsequence (builders ->
	-- finisher, advances only on a landed cast; spells you don't have are trimmed out), and
	-- the steps between each try ONE cooldown. Slice and Dice stays out (re-casting it while
	-- up spammed "A more powerful spell is already active" on Outlaw).
	["Assassination"] = {
		mods = {},
		rev = 1,
		-- Mutilate = 2 combo points: 2 builders -> finisher. Garrote opens the pull and is
		-- refreshed once a cycle; Rupture once per 4 finishers (it lasts far longer than Envenom).
		st = {
			{ ASSA_CORE },
			{ "Deathmark" },
			{ ASSA_CORE },
			{ "Kingsbane" },
			{ ASSA_CORE },
			{ "Shiv" },
		},
		aoe = {
			{ ASSA_AOE },
			{ "Deathmark" },
			{ ASSA_AOE },
			{ "Shiv" },
		},
	},
	["Outlaw"] = {
		mods = {},
		-- rev: re-seeds ONLY this spec when bumped (DEFAULTS_VER would re-seed every character).
		-- rev 1 (2026-10-24): Slice and Dice out -- Outlaw doesn't use it, and re-casting it
		-- while it was up spammed "A more powerful spell is already active".
		-- rev 2 (2026-10-24): combo-point pacing. A macro can't see combo points and a
		-- finisher fires at 1 CP, so the old 6-step cycle (2 finishers) spent at ~2 CP.
		-- Now 4 builders -> 1 finisher (Sinister Strike's extra hits land ~5-6 CP), and
		-- Blade Rush (talent) is woven in.
		-- rev 3 (2026-10-24, cast log): the player mashes key 1 (~5 presses per GCD) and every
		-- press advanced the 5-step cycle, so only the step that happened to line up with the
		-- GCD ending ever cast -- phase-locked on one step (AoE ~ all Sinister Strike; Dispatch /
		-- Between the Eyes almost never). Now ONE step whose builder->finisher order is a
		-- /castsequence, which only advances when a cast LANDS, so mashing can't skip it.
		-- Cooldowns go first and fire whenever they're ready (they fail silently on CD).
		-- Between the Eyes (has a cooldown, so it can't sit inside the castsequence -- it
		-- would stall it) comes after: it fires only when the sequence couldn't cast this
		-- press (mostly short on energy at the Dispatch slot, i.e. with combo points up).
		-- rev 4 (2026-10-24, second cast log): rev 3 cast NOTHING. A /cast of an on-GCD spell
		-- that fails (on cooldown, or during the GCD) ends the macro for that press -- Blade
		-- Flurry / Roll the Bones on cooldown blocked every line after them. Only off-GCD
		-- spells (Adrenaline Rush) fail without blocking. So each press tries at most ONE
		-- on-GCD spell: every other step is the castsequence (builders -> Dispatch, advances
		-- only on a landed cast), the steps between each try one cooldown; one that isn't
		-- ready wastes that press only, and the next press is the castsequence again.
		-- rev 5 (2026-10-25, dungeon): Blade Rush out. It charges you to the target, and
		-- several times that pulled the player in when they needed to get away. Never put
		-- a gap closer in key 1.
		rev = 5,
		st = {
			{ "Adrenaline Rush", OUTLAW_CORE },
			{ "Adrenaline Rush", "Roll the Bones" },
			{ "Adrenaline Rush", OUTLAW_CORE },
			{ "Adrenaline Rush", "Between the Eyes" },
		},
		aoe = {
			{ "Adrenaline Rush", OUTLAW_CORE },
			{ "Adrenaline Rush", "Blade Flurry" },
			{ "Adrenaline Rush", OUTLAW_CORE },
			{ "Adrenaline Rush", "Roll the Bones" },
			{ "Adrenaline Rush", OUTLAW_CORE },
			{ "Adrenaline Rush", "Between the Eyes" },
		},
	},
	["Subtlety"] = {
		mods = {},
		rev = 6,
		-- Backstab (Gloomblade counts) = 1 combo point, plus Shadow Techniques from auto
		-- attacks: 3 builders -> Eviscerate. Midnight: Symbols of Death and Rupture are gone,
		-- Shadow Dance is a 20s cooldown, Secret Technique is baseline (level 25), Shuriken
		-- Tornado is now a chance effect of Shuriken Storm (nothing to press).
		-- rev 2 (2026-10-26, level 90, 12.1.5 Trickster): 4 builders -> Eviscerate (spend at
		-- 6+); Shadow Dance (off-GCD) leads Secret Technique so ST lands inside Dance, the
		-- usual "ST on Dance" macro; Goremaw's Bite (reworked 12.1: bleed on 3 targets) on
		-- its own step. Vanish stays on a key (it drops threat / combat).
		-- rev 3 (same day, top-player cast logs): 1 builder : 1 finisher (rev 2's 4 Backstabs
		-- overcapped). Logs confirm Dance -> Secret Technique, Goremaw's ~47s, Blades ~95s.
		-- Top players also Vanish -> Shadowstrike in the opener; that stays on the Vanish key.
		-- rev 4 (dummy log 2026-10-26: 4 Dances, 2 STs): Shadow Dance has 2 charges, so
		-- "/cast Shadow Dance" spent both while Secret Technique was on cooldown; top players
		-- pair every Dance with an ST. Now ST goes FIRST in that press: on cooldown (or no
		-- combo points / mid-GCD) the on-GCD failure ends the press, so Dance only goes out
		-- right behind a landed ST. A castsequence can't gate it (it re-arms Dance after the
		-- pair, and the 2nd charge goes out unpaired). Cost: ST lands just before Dance.
		-- rev 5 (second dummy log): rev 4's gate didn't hold -- one on-GCD attempt per press,
		-- but Dance is OFF the GCD, so it still went out after ST failed. Worse, the core
		-- deadlocked on Eviscerate at 0 combo points after ST spent them. Now: a builder step
		-- (SUB_BUILD) un-sticks the core; Dance first again (ST gets Dance's bonus) but never
		-- inside a Dance. No macro can check ST's cooldown, so an unpaired Dance can still
		-- happen (mostly the opener's 2nd charge); Dance recharge ~= ST cooldown after that.
		-- rev 6 (third dummy log): no more deadlock, 1.3 builders : 1 finisher. But a ready
		-- cooldown only goes out when ITS step meets the free GCD, so with 1 step in 7 Secret
		-- Technique went out ~7s late and Goremaw's ~10s late. Their steps now come 3x / 2x
		-- per cycle; a step whose spell is still on cooldown costs one press (~0.2s). Shadow
		-- Blades is OFF the GCD (cast 0.35s after a Coup de Grace in the log), so it leads the
		-- core steps instead of owning one, like Outlaw's Adrenaline Rush. (Dance: ~11s with
		-- finishers' cooldown cut, ST ~30s, so only ~1 Dance in 3 can hold an ST.)
		st = {
			{ "Shadow Blades", SUB_CORE },
			{ SUB_DANCE, "Secret Technique" },
			{ "Goremaw's Bite" },
			{ "Shadow Blades", SUB_CORE },
			{ SUB_DANCE, "Secret Technique" },
			{ SUB_BUILD },
			{ "Shadow Blades", SUB_CORE },
			{ SUB_DANCE, "Secret Technique" },
			{ "Goremaw's Bite" },
		},
		-- Shuriken Storm = 1 combo point per enemy hit: 2 storms -> finisher. Black Powder
		-- and Eviscerate alternate (a missing Black Powder is trimmed, Eviscerate remains).
		aoe = {
			{ "Shadow Blades", SUB_AOE },
			{ SUB_DANCE, "Secret Technique" },
			{ "Goremaw's Bite" },
			{ "Shadow Blades", SUB_AOE },
			{ SUB_DANCE, "Secret Technique" },
			{ SUB_AOE_BUILD },
			{ "Shadow Blades", SUB_AOE },
			{ SUB_DANCE, "Secret Technique" },
			{ "Goremaw's Bite" },
		},
	},
}

-- Spec used when the character's current spec has no defaults defined yet.
local DEFAULT_SPEC = "Unholy"
-- Spec API: C_SpecializationInfo, the plain globals only as a fallback (they live in
-- Blizzard's deprecation shims, which can be switched off).
local CSI = C_SpecializationInfo
local GetSpecialization = (CSI and CSI.GetSpecialization) or GetSpecialization
local GetSpecializationInfo = (CSI and CSI.GetSpecializationInfo) or GetSpecializationInfo
local GetSpecializationRole = (CSI and CSI.GetSpecializationRole) or GetSpecializationRole
-- Bump when the DEFAULTS rotations change — forces a one-time re-seed so live
-- characters pick up the updated rotation on their next /reload. (v2: Guardian
-- rebuilt to match top M+ play — Moonfire-spam/Lunar Beam. v3: Ironfur + Barkskin
-- added to the Guardian auto-loop. v4: Unholy rebuilt to match top Unholy play.
-- v5: Restoration (Keeper of the Grove) heal profile added. v6: more Swiftmend in
-- Resto AoE so Efflorescence (the ground circle) stays up. v10: Windwalker profile
-- added, with Expel Harm woven in for leveling self-sustain. v11: Unholy PASS 3 --
-- removed lone cooldown steps that dead-pressed and ate Soul Reaper/Festering Strike.
-- v12: Unholy PASS 3.5 -- Festering Strike 2 lead steps -> 1 (was over-building Lesser
-- Ghoul stacks ~1:1 vs the top's ~1:3-4, per a live dummy read).) v18: Rogue
-- specs added (Assassination / Outlaw / Subtlety) as leveling basics.
-- v19: Shadow ST/AoE aligned to top Voidweaver profile (Tentacle Slam ->2 steps,
-- Void Volley added). + "!" force-anchor on toggle/form spells (Shadowform drop fix).
-- v20: Shadow ST/AoE interleave Mind-Flay-lead steps so the filler fires under fast
-- mashing (step-cycler advances per press; buried Mind Flay was landing 0/30).
-- v21: Shadow ST rebalanced -- 4 Mind-Flay-lead steps -> 2 (EXP4 over-fed the
-- filler under paced tapping, starving Mind Blast/SW:Madness).
-- v53: Rogue -- no held modifiers; Adrenaline Rush / Shadow Dance / Deathmark woven in.
local DEFAULTS_VER = 53
-- Updated on login + spec change. modPrefix/seeding read it.
local currentSpec = DEFAULT_SPEC
-- Globally-unique spec id (e.g. 251 = Frost DK). Used to look up recommended builds,
-- since spec NAMES collide across classes (Frost DK vs Frost Mage, Holy Pal vs Priest).
local currentSpecID = nil

local function specDefaults()
	return DEFAULTS[currentSpec] or DEFAULTS[DEFAULT_SPEC]
end

-- Current spec NAME (e.g. "Guardian"), falling back if the API isn't ready. Also stashes
-- the spec id for build lookups.
-- WoW Forever (Classic+ on the modern client, TOC 16001) has no specs: rotations
-- there are keyed by class, "FOREVER_<CLASSFILE>" (e.g. FOREVER_PALADIN).
local IS_FOREVER = (select(4, GetBuildInfo()) or 0) < 100000

-- Generated rotations (Rotations.lua, from voidscout-data/tools/cmd/rotation-pull): one
-- per spec and hero tree, built from the top players' casts, so every spec has one. They
-- join DEFAULTS as "<Spec>:<Hero>" (hero trees belong to one class, so those keys never
-- collide); a hand-tuned entry under the same key wins. Spec NAMES do collide (Restoration,
-- Frost, Holy, Protection), so a hand entry with `class` only loads for that class.
local function genSteps(list)
	local out = {}
	for i, spell in ipairs(list or {}) do out[i] = { spell } end
	return out
end
-- A cheap content hash: a regenerated rotation reseeds like a hand-tuned rev bump.
local function genRev(r)
	local s, h = table.concat(r.st or {}, ",") .. "|" .. table.concat(r.aoe or {}, ","), 0
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
	return h
end
local function registerGen(specID, name)
	local g = VS.GenRotations and VS.GenRotations[specID]
	if not (g and name) then return end
	local _, classFile = UnitClass("player")
	for hero, r in pairs(g) do
		local key = name .. ":" .. hero
		if not DEFAULTS[key] then
			local d = { st = genSteps(r.st), aoe = genSteps(r.aoe), mods = {}, hero = hero, class = classFile,
				gen = true, players = r.players, rev = genRev(r), fallback = r.fallback }
			if r.heal then
				-- healers: one loop like the Resto Druid one; heals land on who you hover,
				-- damage on a hovered enemy, else heals go on you
				d.oneMode, d.healSelfLast, d.channelGuard = true, true, true
				d.aoe = d.st
				d.cond = {}
				for _, list in ipairs({ r.st or {}, r.fallback or {} }) do
					for _, spell in ipairs(list) do
						d.cond[spell] = (r.heals and r.heals[spell]) and HEAL_HOVER or DMG_HOVER
					end
				end
			end
			DEFAULTS[key] = d
		end
	end
end
local function fitsClass(key)
	local d = key and DEFAULTS[key]
	if not d then return false end
	local _, classFile = UnitClass("player")
	return not d.class or d.class == classFile
end
-- The generated rotation to use before you have a hero tree (under level 71): the hero
-- tree of the spec's most-played build (first in Builds.lua), else the first one sorted.
local function firstGenHero(specID)
	local g, first = VS.GenRotations and VS.GenRotations[specID], nil
	if not g then return nil end
	local top = VS.RecoBuilds and VS.RecoBuilds[specID] and VS.RecoBuilds[specID][1]
	local topHero = top and top.name and top.name:gsub("%s*%(.-%)%s*$", "")
	if topHero and g[topHero] then return topHero end
	for hero in pairs(g) do
		if not first or hero < first then first = hero end
	end
	return first
end

-- Before level 10 there is no spec. The class's own leveling buttons (the fallback list
-- every generated rotation of the class carries) make the rotation then; without data
-- there is none. Before, a spec-less character of ANY class got the Unholy rotation
-- (Codex review, 2026-10-30).
local NO_SPEC = "No spec yet"
local function levelingKey()
	local _, classFile, classID = UnitClass("player")
	if not classFile then return NO_SPEC end
	local key = "Leveling:" .. classFile
	if DEFAULTS[key] then return key end
	local count = (CSI and CSI.GetNumSpecializationsForClassID and CSI.GetNumSpecializationsForClassID(classID))
		or (GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID)) or 0
	for i = 1, count do
		local specID = GetSpecializationInfoForClassID and GetSpecializationInfoForClassID(classID, i)
		for _, r in pairs(VS.GenRotations and specID and VS.GenRotations[specID] or {}) do
			if r.fallback and #r.fallback > 0 then
				DEFAULTS[key] = { st = genSteps(r.fallback), aoe = genSteps(r.fallback), mods = {},
					class = classFile, gen = true, rev = 1 }
				return key
			end
		end
	end
	return NO_SPEC
end

local function detectSpec()
	if IS_FOREVER then
		local _, classFile = UnitClass("player")
		currentSpecID = nil
		return classFile and ("FOREVER_" .. classFile) or DEFAULT_SPEC
	end
	local i = GetSpecialization and GetSpecialization()
	if not i then return levelingKey() end
	local specID, name = GetSpecializationInfo(i)
	currentSpecID = specID
	if not name then return levelingKey() end
	registerGen(specID, name)
	-- Hero-tree variant (2026-10-28): a spec can carry one rotation per hero tree, keyed
	-- "<Spec>:<Hero>" (Unholy:San'layn). The active hero tree picks it, else the plain entry.
	local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
	local sub = cfg and C_ClassTalents.GetActiveHeroTalentSpec and C_ClassTalents.GetActiveHeroTalentSpec()
	local info = sub and C_Traits.GetSubTreeInfo(cfg, sub)
	local hero = info and info.name
	-- 1) the rotation picked for this spec in the options (VS.SetRotationPick)
	local pick = VoidSequencerCharDB and VoidSequencerCharDB.rotPick and VoidSequencerCharDB.rotPick[specID]
	if pick and fitsClass(pick) then return pick end
	-- 2) a hand-tuned rotation for this hero tree
	local heroKey = hero and (name .. ":" .. hero)
	if heroKey and fitsClass(heroKey) and not DEFAULTS[heroKey].gen then return heroKey end
	-- 3) the hand-tuned spec rotation, unless it was built for another hero tree and a
	--    generated one matches the active tree
	if fitsClass(name) then
		local h = DEFAULTS[name].hero
		if not (h and hero and h ~= hero and fitsClass(heroKey)) then return name end
	end
	-- 4) the generated rotation for this hero tree, else the spec's first one
	if heroKey and fitsClass(heroKey) then return heroKey end
	local first = firstGenHero(specID)
	if first then return name .. ":" .. first end
	return name
end

-- The rotations this spec can run, for the options picker: hand-tuned ones first, then
-- one generated per hero tree. { key, label }.
function VS.RotationChoices()
	local i = GetSpecialization and GetSpecialization()
	local specID, name
	if i then specID, name = GetSpecializationInfo(i) end
	if not name then return {} end
	registerGen(specID, name)
	local out = {}
	for key, d in pairs(DEFAULTS) do
		if (key == name or key:sub(1, #name + 1) == name .. ":") and fitsClass(key) then
			local label = (key:gsub("^[^:]+:", ""))
			if key == name then label = name .. (d.hero and (" (" .. d.hero .. ")") or "") end
			if d.gen then
				label = label .. " (Top players, beta)"
			else
				label = label .. " (Tuned)"
			end
			out[#out + 1] = { key = key, label = label, gen = d.gen }
		end
	end
	table.sort(out, function(a, b)
		if (a.gen or false) ~= (b.gen or false) then return not a.gen end
		return a.label < b.label
	end)
	return out
end
function VS.GetRotationPick()
	local i = GetSpecialization and GetSpecialization()
	local specID = i and GetSpecializationInfo(i)
	return specID and VoidSequencerCharDB and VoidSequencerCharDB.rotPick and VoidSequencerCharDB.rotPick[specID]
end

-- "Unholy:San'layn" -> "Unholy (San'layn)" for chat and the options panel.
local function specLabel(key)
	return (tostring(key):gsub("^([^:]+):(.+)$", "%1 (%2)"))
end
VS.SpecLabel = specLabel

-- deep-copy a sequence (list of {spell,...} steps) so SV never aliases a default.
local function copySeq(src)
	local out = {}
	for i, step in ipairs(src) do
		local s = {}
		for j, spell in ipairs(step) do s[j] = spell end
		out[i] = s
	end
	return out
end

-- Build one modifier's /cast line. Abilities in CONDITIONALS (heals/externals)
-- keep their targeting (mouseover the hovered frame, then target, then self) with
-- the modifier injected into every clause; everything else is a plain self-cast
-- under the held modifier. Empty slot -> nil (skipped).
local function modCast(mod, spell)
	if not spell or spell == "" then return nil end
	local cond = CONDITIONALS[spell]
	if cond and cond ~= "" then
		return "/cast " .. cond:gsub("%[", "[mod:" .. mod .. ",") .. spell
	end
	return "/cast [mod:" .. mod .. "]" .. spell
end

-- Global modifier prepends, applied to EVERY step so a held modifier fires its
-- assigned ability at any point in the rotation. Assignments live in
-- VoidSequencerDB.mods ({alt=,ctrl=,shift=}), seeded per spec + rebindable in the
-- options panel's modifier pickers. No modifier held -> the [mod:*] lines fail
-- and fall through to the real rotation.
local function modPrefix()
	local m = VoidSequencerDB and VoidSequencerDB.mods or {}
	local lines = {}
	for _, mod in ipairs({ "alt", "ctrl", "shift" }) do
		local c = modCast(mod, m[mod])
		if c then lines[#lines + 1] = c end
	end
	if #lines == 0 then return "" end
	return table.concat(lines, "\n") .. "\n"
end

-- Toggle/stance/form/aura abilities that CANCEL when re-cast. A blind spam that
-- loops back onto one of these while it's already active would toggle it OFF --
-- e.g. re-casting Voidform/Shadowform drops you out of form, which is exactly the
-- "must be in Shadowform" errors seen in a +10 log (23x). The "!" force
-- anchor makes the game turn the form ON but never OFF. Harmless on non-toggle
-- spells (a no-op there), so this list is safe to keep broad. Injected in
-- stepToMacro so the DEFAULTS arrays stay pure spell names (CONDITIONALS + any
-- future icon rendering keep matching).
local TOGGLE_SPELLS = {
	["Shadowform"] = true, ["Voidform"] = true,
	["Bear Form"] = true, ["Cat Form"] = true, ["Moonkin Form"] = true,
	["Stealth"] = true, ["Prowl"] = true, ["Metamorphosis"] = true,
}

-- A /castsequence stalls for good on a spell you don't have (a talent you skipped, a
-- spell you only get later while leveling), so its unknown spells are left out of the
-- macro. Only once the spellbook has loaded -- before that nothing is trimmed -- and the
-- macros are rebuilt when your spells change (SPELLS_CHANGED). Talent overrides count
-- as known (Gloomblade over Backstab).
-- Buttons that only exist while a buff transforms another spell (DB2 aura 332 targets).
-- Out of combat, when the macros are rebuilt, the game calls them unknown, so they're
-- never trimmed. Generated rotations use the base button instead.
local TRANSFORMS = { ["Void Volley"] = true, ["Rushing Wind Kick"] = true }
local function knownForMacro(name)
	if TRANSFORMS[name] then return true end
	local info = C_Spell.GetSpellInfo(name)
	local id = info and info.spellID
	if not id then return false end
	if C_SpellBook.IsSpellKnownOrInSpellBook then return C_SpellBook.IsSpellKnownOrInSpellBook(id) and true or false end
	return C_SpellBook.IsSpellKnown(id) and true or false
end
local function spellbookReady()
	return C_SpellBook.GetNumSpellBookSkillLines and (C_SpellBook.GetNumSpellBookSkillLines() or 0) > 0
end
local function trimSequence(line)
	local body = line:match("^/castsequence%s+(.*)$")
	if not body or not spellbookReady() then return line end
	local opts = {}
	while true do   -- leading options: [conditions] and reset=...
		local o = body:match("^(%b[])%s*") or body:match("^(reset=%S+)%s*")
		if not o then break end
		opts[#opts + 1] = o
		body = body:sub(#o + 1):gsub("^%s+", "")
	end
	-- ";" alternatives / further [conditions]: syntax this trimmer doesn't parse -> as-is
	if body:find("[;%[]") then return line end
	local keep, real = {}, false
	for part in body:gmatch("[^,]+") do
		local s = strtrim(part)
		if s == "null" then
			keep[#keep + 1] = s
		elseif s ~= "" and knownForMacro((s:gsub("^!", ""))) then
			keep[#keep + 1] = s
			real = true
		end
	end
	if not real then return nil end
	opts[#opts + 1] = table.concat(keep, ", ")
	return "/castsequence " .. table.concat(opts, " ")
end

-- One step (priority list of spells) -> one macro block string.
-- channelGuard specs (casters) get a [nochanneling] prefix on every rotation cast, so a
-- press mid-channel (e.g. Mind Flay / Void Torrent) can't clip it -- it no-ops until the
-- channel ends. Does NOT protect hardcasts (no macro conditional exists for those; they
-- still need press-at-cadence). Held-modifier lines are left unguarded so you can always
-- panic-cast a defensive during a channel. Read live from DEFAULTS, so it applies on a
-- plain /reload (no re-seed needed).
local function stepToMacro(step)
	local d = DEFAULTS[currentSpec]
	local guard = (d and d.channelGuard) and "[nochanneling]" or ""
	-- Per-spec targeting (d.cond) wins over the shared CONDITIONALS table.
	local function condFor(spell) return (d and d.cond and d.cond[spell]) or CONDITIONALS[spell] or "" end
	-- Guard EVERY clause: "[@mouseover,help][help]" with only the first guarded still
	-- cast through the second clause mid-channel (Tranquility / Convoke clipped).
	local function guarded(cond)
		if guard == "" then return cond end
		return (cond ~= "") and cond:gsub("%[", "[nochanneling,") or guard
	end
	local lines = {}
	local daggerMH = MainHandIsDagger()
	local firstHeal
	for _, spell in ipairs(step) do
		if daggerMH and NO_DAGGER_MH[spell] then
			-- left out: fails with a dagger in the main hand
		elseif spell and spell:sub(1, 1) == "/" then
			-- Raw macro line (e.g. "/castsequence reset=combat Seal of X, Judgement"):
			-- passed through as-is, for things a plain /cast list can't express
			-- (a castsequence minus the spells you don't have yet).
			local line = trimSequence(spell)
			if line then lines[#lines + 1] = line end
		elseif spell and spell ~= "" and spellbookReady() and not knownForMacro(spell) then
			-- left out: not learned yet (leveling) or not talented. SPELLS_CHANGED rebuilds
			-- the macros, so it joins the rotation the moment you learn it.
		elseif spell and spell ~= "" then
			local cond = condFor(spell)
			if not firstHeal and cond:find("help", 1, true) then firstHeal = spell end
			local force = TOGGLE_SPELLS[spell] and "!" or ""   -- ensure-on, never toggle-off
			lines[#lines + 1] = "/cast " .. guarded(cond) .. force .. spell
		end
	end
	-- Healer specs: nobody friendly hovered and no target at all -> heal yourself. The
	-- /stopmacro keeps a failed hovered heal (out of range) or a target from ending up on you.
	if d and d.healSelfLast and firstHeal then
		lines[#lines + 1] = "/stopmacro [@mouseover,help,nodead][exists]"
		lines[#lines + 1] = "/cast " .. guarded("[@player]") .. firstHeal
	end
	-- second value: how many casts the step has left (0 = every spell in it is unknown)
	return modPrefix() .. table.concat(lines, "\n"), #lines
end

-- Live sequence accessor (reads straight from SV; the editor mutates these).
local function seqFor(mode) -- mode == "AOE" or "ST"
	if mode == "AOE" then return VoidSequencerDB.seqAOE else return VoidSequencerDB.seqST end
end

-- WoW macros cap at 255 chars. If a Priority-mode macro overflows, drop the trailing
-- (lowest-priority) /cast lines so it stays a valid macro instead of truncating mid-line.
local function capMacro(text)
	if #text <= 255 then return text end
	local out, total = {}, 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if total + #line + 1 > 255 then break end
		out[#out + 1] = line
		total = total + #line + 1
	end
	return table.concat(out, "\n")
end

-- Priority mode: collapse a mode to a SINGLE step holding every ability in priority
-- order. The engine casts the first CASTABLE spell in the current step, and with one
-- step there's no counter to race -- each press just fires your best available ability,
-- so mashing is harmless. Uses an explicit DEFAULTS[spec].priST / priAOE where defined,
-- else flattens the editor sequence (first occurrence = highest priority).
local function priorityList(mode)
	local d = DEFAULTS[currentSpec]
	local explicit = d and (mode == "AOE" and d.priAOE or d.priST)
	if explicit then return explicit end
	local seen, out = {}, {}
	for _, step in ipairs(seqFor(mode) or {}) do
		for _, sp in ipairs(step) do
			if sp and sp ~= "" and not seen[sp] then seen[sp] = true; out[#out + 1] = sp end
		end
	end
	return out
end

-- Steps to load for a mode: one flat priority step when Priority mode is on, else the
-- full timed sequence.
local function seqOrPriority(mode)
	-- Priority mode (one step holding every spell) is gone: a press makes ONE on-GCD try,
	-- so it only ever tried the first spell (memory wow-macro-ongcd-fail-blocks).
	return seqFor(mode)
end

-- ---------------------------------------------------------------------------
-- Secure casting button + step-advancing wrap-script.
-- ---------------------------------------------------------------------------
-- Secure setup. TWO things are essential (the standard one-button-addon pattern):
--   1. BOTH templates: SecureActionButtonTemplate + SecureHandlerBaseTemplate.
--   2. The macro strings live in the button's SECURE restricted environment
--      (loaded via :Execute), NOT as insecure attributes. A macrotext set from a
--      secure value can run /cast; one derived from an insecure attribute gets
--      the protected cast BLOCKED (the "/startattack works, /cast doesn't" bug).
local btn = CreateFrame("Button", "VoidSeqButton", nil, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
-- Register BOTH up and down: depending on the cast-on-key-down/up cvar, the
-- protected cast fires on the up event. Registering only Down ran the macro
-- (/startattack) but never delivered the cast. A "stepped" gate in the snippet
-- prevents the down+up pair from double-advancing.
btn:RegisterForClicks("AnyUp", "AnyDown")
btn:SetAttribute("type", "macro")
btn:SetAttribute("step", 1)

-- Load steps into the SECURE environment using Lua LONG-STRING brackets
-- ([=======[ ... ]=======]). Long strings preserve real
-- newlines verbatim with NO escaping — which is the whole fix. (%q and manual
-- escaping both mangled the multi-line macro down to just its first line.) The
-- 7 equals signs ensure a "]" inside "[mod:shift]" can't close the string early.
local function loadTable(name, seq, numVar, lines, noAttack, fallback)
	lines[#lines + 1] = name .. " = newtable()"
	-- /startattack prepended for melee auto-attack; long-string embedding
	-- preserves real newlines (see the recipe — %q mangles them). Each step
	-- is GENERATED from its spell list here, so editor changes flow straight in.
	-- Healer loops skip it: with a friendly hovered/targeted it errors "nothing to
	-- attack" on every press (Resto, 2026-10-27); their cat loop keeps it.
	-- Steps whose spells you don't have yet are skipped, so a leveling character presses
	-- only what it knows (no dead presses); the rest keep their order and share.
	local kept = {}
	for i = 1, #seq do
		local body, casts = stepToMacro(seq[i])
		if casts > 0 then kept[#kept + 1] = body end
	end
	-- A low-level character may know only one or two of the rotation's spells: then the
	-- class's leveling buttons (d.fallback, generated rotations) fill in, the known ones
	-- only. At max level the rotation is all known and these never load.
	if #kept < 3 and fallback then
		for _, spell in ipairs(fallback) do
			local body, casts = stepToMacro({ spell })
			if casts > 0 and not (C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spell)) then kept[#kept + 1] = body end
		end
	end
	if #kept == 0 then   -- nothing known (spellbook not loaded yet): the full list as-is
		for i = 1, #seq do kept[i] = (stepToMacro(seq[i])) end
	end
	for i, body in ipairs(kept) do
		local head = noAttack and "" or "/startattack\n"
		local macro = head .. body
		if #macro > 255 and modPrefix() ~= "" and body:sub(1, #modPrefix()) == modPrefix() then
			macro = head .. body:sub(#modPrefix() + 1)   -- the rotation line wins over held-key extras
		end
		macro = capMacro(macro)
		lines[#lines + 1] = name .. "[" .. i .. "] = [=======[" .. macro .. "]=======]"
	end
	lines[#lines + 1] = numVar .. " = " .. #kept
end

-- Rebuild the secure macro tables from the SV sequences. MUST run out of combat
-- (btn:Execute writes the restricted env); queues to PLAYER_REGEN_ENABLED if
-- locked down. Single "apply my edits" entry point used by the options editor.
local seqDirty = false
local loadedText
-- onlyIfChanged: skip when the macros come out the same (SPELLS_CHANGED fires often).
local function LoadSequences(onlyIfChanged)
	local lines = {}
	local d = DEFAULTS[currentSpec]
	local noAttack = d and d.healSelfLast   -- healer loops: no /startattack
	local fb = d and d.fallback
	loadTable("macrosST", seqOrPriority("ST"), "numST", lines, noAttack, fb)
	loadTable("macrosAOE", seqOrPriority("AOE"), "numAOE", lines, noAttack, fb)
	-- Optional form loop (d.formLoop = { rule = "<conditions> form; ...", seq = {...} }):
	-- the click snippet runs it when the rule says "form" (Resto: Cat Form, no friendly hovered).
	local fl = d and d.formLoop
	loadTable("macrosFORM", (fl and fl.seq) or {}, "numFORM", lines)
	lines[#lines + 1] = "formRule = " .. ((fl and fl.rule) and ("[=======[" .. fl.rule .. "]=======]") or "nil")
	local text = table.concat(lines, "\n")
	if onlyIfChanged and text == loadedText then return end
	if InCombatLockdown() then seqDirty = true; return end
	loadedText = text
	btn:Execute(text)
	btn:SetAttribute("step", 1)
	btn:SetAttribute("fstep", 1)
	btn:SetAttribute("stepped", false)
end

-- Pre-click secure snippet: set this press's macro from the secure table, then
-- advance. The "stepped" gate stops the down+up pair from double-advancing,
-- while leaving the macro set for whichever event the cast-key cvar fires on.
btn:WrapScript(btn, "OnClick", [[
	if self:GetAttribute("stepped") then
		self:SetAttribute("stepped", false)
		return
	end
	-- [channeling] advance-gate: while channeling (Mind Flay / Void Torrent), do
	-- NOT advance the index. The [nochanneling] macro no-ops the cast anyway, so
	-- without this every press during a ~3s channel BURNS a step (skips ahead).
	-- Holding the index means auto-spamming through a channel lands on the CORRECT
	-- next step the instant it ends -- kills the 3-4s channel stalls on long channels.
	-- "vschan" is set SECURELY by RegisterStateDriver below (no taint; same tech
	-- as action-bar paging). This does nothing to a slow presser; it makes fast
	-- spam channel-safe.
	local chan = self:GetAttribute("state-vschan")
	if chan == 1 or chan == "1" then
		return
	end
	-- Form loop (Resto cat weaving): in Cat Form and NOT hovering a friendly frame, run
	-- the cat loop on its own step counter. Hovering a friendly falls through to the heal
	-- loop, whose heal drops you out of cat. formRule / macrosFORM come from LoadSequences.
	if formRule and numFORM and numFORM > 0 and SecureCmdOptionParse(formRule) == "form" then
		local fs = self:GetAttribute("fstep") or 1
		if fs > numFORM then fs = 1 end
		self:SetAttribute("type", "macro")
		self:SetAttribute("macrotext", macrosFORM[fs])
		self:SetAttribute("stepped", true)
		fs = fs + 1
		if fs > numFORM then fs = 1 end
		self:SetAttribute("fstep", fs)
		return
	end
	-- pick the rotation for the current mode (toggled in/out of combat)
	local aoe = self:GetAttribute("aoe")
	local macros = aoe and macrosAOE or macrosST
	local n = aoe and numAOE or numST
	if not macros or not n or n < 1 then return end
	local step = self:GetAttribute("step") or 1
	if step > n then step = 1 end
	self:SetAttribute("type", "macro")
	self:SetAttribute("macrotext", macros[step])
	self:SetAttribute("stepped", true)
	step = step + 1
	if step > n then step = 1 end
	self:SetAttribute("step", step)
]])

-- [channeling] state driver: sets btn's SECURE "vschan" attribute to "1" while
-- channeling, "0" otherwise, updated by the game even in combat. Read by the
-- OnClick gate above so spamming through a channel doesn't burn/skip steps.
-- State drivers are the canonical secure mechanism -- no taint, no insecure
-- clock feeding the button (that was the blocked path). Registered out of combat.
RegisterStateDriver(btn, "vschan", "[channeling] 1; 0")

-- ---------------------------------------------------------------------------
-- ST/AoE mode toggle. A clickable SECURE handler button that flips the "aoe"
-- attribute on the cast button — works in combat (hardware click + secure
-- snippet manipulating a ref'd frame's attribute). NOT a held modifier.
-- ---------------------------------------------------------------------------
local toggle = CreateFrame("Button", "VoidSeqToggle", UIParent, "SecureHandlerBaseTemplate,UIPanelButtonTemplate")
toggle:RegisterForClicks("AnyUp")
SecureHandlerSetFrameRef(toggle, "seq", btn)
SecureHandlerWrapScript(toggle, "OnClick", toggle, [[
	local seq = self:GetFrameRef("seq")
	seq:SetAttribute("aoe", not seq:GetAttribute("aoe"))
]])

-- The button shows the mode you are CURRENTLY in (not the one it switches to).
local function modeLabel(aoe)
	return aoe and "|cffffaa00AoE mode|r" or "|cff55ff55Single Target|r"
end

-- ---------------------------------------------------------------------------
-- Error-spam suppression. A one-button priority stack constantly attempts
-- abilities that aren't usable yet (Soul Reaper out of execute, cooldowns,
-- resource gaps) — each failed /cast throws a red "you can't do that" message.
-- Filter the known cast-failure spam from the error frame. Cosmetic only; the
-- secure cast path is untouched.
-- ---------------------------------------------------------------------------
local ERR_FILTER = {}
for _, k in ipairs({
	"ERR_ABILITY_COOLDOWN", "ERR_SPELL_COOLDOWN", "ERR_OUT_OF_RUNIC_POWER",
	"ERR_OUT_OF_RUNES", "ERR_OUT_OF_ENERGY", "ERR_OUT_OF_FOCUS",
	"SPELL_FAILED_NOT_READY", "SPELL_FAILED_SPELL_IN_PROGRESS",
	"SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_BAD_IMPLICIT_TARGETS",
	"SPELL_FAILED_OUT_OF_RANGE", "ERR_OUT_OF_RANGE", "ERR_GENERIC_NO_TARGET",
	"SPELL_FAILED_UNIT_NOT_INFRONT", "ERR_GENERIC_NO_VALID_TARGETS",
	"SPELL_FAILED_TARGET_AURASTATE", "SPELL_FAILED_CASTER_AURASTATE",
	"SPELL_FAILED_MOVING", "SPELL_FAILED_NOT_BEHIND", "SPELL_FAILED_NOT_INFRONT",
	"SPELL_FAILED_NO_POWER", "ERR_NOT_ENOUGH_POWER",
}) do
	if _G[k] then ERR_FILTER[_G[k]] = true end
end
local _origAddMessage = UIErrorsFrame.AddMessage
UIErrorsFrame.AddMessage = function(self, msg, ...)
	if type(msg) == "string" and ERR_FILTER[msg] then return end
	return _origAddMessage(self, msg, ...)
end

-- ---------------------------------------------------------------------------
-- Cadence pacer. A green BORDER glow on the ST/AoE button that lights up when
-- you're OFF the global cooldown and not casting/channeling -- i.e. "a press
-- will LAND now." The step-cycler advances on EVERY press, so mashing faster
-- than the GCD skips steps; tapping in rhythm with the glow lands one cast per
-- press. The glow is a separate frame anchored TO (not parented INTO) the toggle
-- so it follows it without tainting the secure button. Toggle in the options.
-- ---------------------------------------------------------------------------
local GCD_SPELL = 61304  -- Blizzard's Global Cooldown spell: its cooldown IS the GCD
local function voidseq_onGCD()
	local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(GCD_SPELL)
	if info and (info.duration or 0) > 0 then
		return (info.startTime + info.duration) > GetTime()
	end
	return false
end

local pacer = CreateFrame("Frame", "VoidSeqPacer", UIParent, "BackdropTemplate")
-- MEDIUM (matching the toggle button), NOT HIGH -- HIGH made it float OVER full-
-- screen panels like the Great Vault. Sit just above the button in the same strata.
pacer:SetFrameStrata("MEDIUM")
pacer:SetFrameLevel(toggle:GetFrameLevel() + 5)
pacer:SetPoint("TOPLEFT", toggle, "TOPLEFT", -3, 3)
pacer:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", 3, -3)
pacer:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 3 })
pacer:SetBackdropBorderColor(0.25, 1.0, 0.4, 0)   -- green, hidden until ready
pacer:Hide()

local function pacerEnabled()
	return not (VoidSequencerDB and VoidSequencerDB.pacer == false)
end

-- Show/run the glow ONLY IN COMBAT. Out of combat you're always off-GCD, so the
-- border would sit permanently lit over whatever's on screen (the reported bug:
-- an empty green box over the Great Vault). Hiding out of combat also stops the
-- OnUpdate from running while idle (hidden frames don't tick).
local function pacerRefresh()
	if pacerEnabled() and UnitAffectingCombat("player") then
		pacer:Show()
	else
		pacer:SetBackdropBorderColor(0.25, 1.0, 0.4, 0)
		pacer:Hide()
	end
end

pacer:SetScript("OnUpdate", function(self, elapsed)
	self._t = (self._t or 0) + elapsed
	if self._t < 0.04 then return end
	self._t = 0
	local busy = UnitCastingInfo("player") or UnitChannelInfo("player")
	-- no glow while the button itself is hidden (VoidBars hides it in skinned vehicles)
	local ready = toggle:IsVisible() and (not busy) and (not voidseq_onGCD())
	self:SetBackdropBorderColor(0.25, 1.0, 0.4, ready and 1 or 0)
end)

pacer:RegisterEvent("PLAYER_LOGIN")
pacer:RegisterEvent("PLAYER_REGEN_DISABLED")  -- entered combat
pacer:RegisterEvent("PLAYER_REGEN_ENABLED")   -- left combat
pacer:SetScript("OnEvent", function(_, event)
	VoidSequencerDB = VoidSequencerDB or {}
	if VoidSequencerDB.pacer == nil then VoidSequencerDB.pacer = true end
	pacerRefresh()
end)

function VS.SetPacer(on)
	VoidSequencerDB = VoidSequencerDB or {}
	VoidSequencerDB.pacer = on and true or false
	pacerRefresh()
end
function VS.GetPacer() return not (VoidSequencerDB and VoidSequencerDB.pacer == false) end

-- ---------------------------------------------------------------------------
-- Keybind handling. SetOverrideBindingClick must run out of combat; queue if
-- we're locked down and apply on PLAYER_REGEN_ENABLED.
-- ---------------------------------------------------------------------------
-- Vehicle pass-through. The rotation key is a REAL binding (SetBindingClick),
-- which outranks the action bar even inside a vehicle — so the key would fire the
-- rotation, not the vehicle's button. This secure state handler watches vehicle/
-- possess/override-bar/skyriding state and, while you're in one, sets a PRIORITY override
-- sending the key to ACTIONBUTTON1 (the vehicle's slot 1). Priority overrides
-- outrank the real binding, so the vehicle works; on exit the override clears and
-- the rotation key is itself again. Secure state driver -> works in combat too
-- (boss vehicles). HANDLE:SetBinding / ClearBindings verified in RestrictedFrames.lua.
local vehHandler = CreateFrame("Frame", "VoidSeqVehicle", UIParent, "SecureHandlerStateTemplate")
-- With VoidBars running, Blizzard's main bar is parked and no longer pages, so
-- ACTIONBUTTON1 would still fire the normal slot 1 ("can't attack while mounted").
-- Then the key goes to VoidBars' own bar-1 button 1, which does page (attribute
-- "voidbtn"). Seen in the VoidBars key log 2026-10-24.
vehHandler:SetAttribute("_vsapply", [[
	self:ClearBindings()
	local key = self:GetAttribute("voidkey")
	if not key or key == "" or self:GetAttribute("state-vehicle") ~= "in" then return end
	local btn = self:GetAttribute("voidbtn")
	if btn and btn ~= "" then
		self:SetBindingClick(true, key, btn, "Keybind")
	else
		self:SetBinding(true, key, "ACTIONBUTTON1")
	end
]])
vehHandler:SetAttribute("_onstate-vehicle", [[ self:RunAttribute("_vsapply") ]])
-- [bonusbar:5] = skyriding: the main bar becomes the skyriding abilities, and key 1
-- has to be ability 1 (Surge Forward) instead of the attack rotation (2026-10-24).
-- That bar stays up after landing while still mounted, so on the ground with a live
-- hostile target key 1 is the rotation again: its cast dismounts and attacks
-- (2026-10-25; seen on a DK and a rogue: key 1 hit the skyriding slot, which
-- does nothing on the ground). On the ground with no target it stays the skyriding slot.
RegisterStateDriver(vehHandler, "vehicle",
	"[vehicleui][overridebar][possessbar] in; [bonusbar:5,flying] in; [bonusbar:5,harm,nodead] out; [bonusbar:5] in; out")

-- Out of combat only. Re-runs the handler so a reload while already mounted (the
-- state fired before the key was known) or a VoidBars takeover takes effect now.
local function SyncVehicleKey()
	if InCombatLockdown() then return end
	local vb = _G.VoidBars
	local btn = vb and vb.blizzardHidden and _G.VoidBarsbar1Button1
	vehHandler:SetAttribute("voidbtn", btn and btn:GetName() or "")
	vehHandler:Execute([[ self:RunAttribute("_vsapply") ]])
end

local pendingKey
local pendingEnable
-- Push the saved ST/AoE mode to the secure button (+ the switch's label). The attribute
-- is protected in combat: deferred to PLAYER_REGEN_ENABLED then. Returns the mode.
local pendingMode
local pendingPlace   -- the switch's position, waiting for combat to end
local function PushMode()
	local aoe = VoidSequencerDB and VoidSequencerDB.aoe and true or false
	toggle:SetText(modeLabel(aoe))
	if InCombatLockdown() then pendingMode = true return aoe end
	btn:SetAttribute("aoe", aoe)
	return aoe
end
-- Restore the key to whatever was bound there BEFORE VoidSequencer grabbed it
-- (e.g. ACTIONBUTTON1), so disabling frees the key for the user's own bar again --
-- the "try it, disable it, put a spell back on 1" flow.
local function ReleaseKey(key)
	if not key or InCombatLockdown() then return end
	local orig = VoidSequencerDB and VoidSequencerDB.keyOrig
	if orig and orig ~= "" and not orig:find("VoidSeqButton") then
		SetBinding(key, orig)
	else
		SetBinding(key)
	end
	vehHandler:SetAttribute("voidkey", "")
	SyncVehicleKey()
end
local function ApplyKey(key)
	if not key then return end
	if InCombatLockdown() then pendingKey = key; return end
	-- Master enable toggle OFF -> don't grab the key; release it so the user's own
	-- keybind/bar on that key keeps working.
	if not (VoidSequencerDB and VoidSequencerDB.enabled) then ReleaseKey(key); return end
	-- Record what was bound to this key before we take it, so disabling can restore
	-- it. Guard against re-capturing our OWN binding on relogs where it persisted.
	local prev = GetBindingAction and GetBindingAction(key)
	if prev and prev ~= "" and not prev:find("VoidSeqButton") then
		VoidSequencerDB.keyOrig = prev
	end
	-- A REAL binding (SetBindingClick), NOT an override. An override
	-- binding runs the macro (so /startattack fires) but does NOT deliver the
	-- protected /cast. Clear the key first, then bind it to left-click the button.
	SetBinding(key)
	SetBindingClick(key, "VoidSeqButton", "LeftButton")
	-- hand the vehicle pass-through handler the current key (out of combat only)
	vehHandler:SetAttribute("voidkey", key)
	SyncVehicleKey()
end

-- ---------------------------------------------------------------------------
-- The ST/AoE switch — a standalone, MOVABLE button. (The on-screen keybind tile
-- is gone; the keybind lives in the options panel now.) Left-click flips mode
-- (secure, works in combat); right-click-drag repositions; position is saved.
-- ---------------------------------------------------------------------------
toggle:ClearAllPoints()
toggle:SetSize(110, 22)
toggle:RegisterForClicks("LeftButtonUp")
toggle:SetText(modeLabel(false))
toggle:HookScript("PostClick", function(self)
	local aoe = btn:GetAttribute("aoe") and true or false
	self:SetText(modeLabel(aoe))
	if VoidSequencerDB then VoidSequencerDB.aoe = aoe end
end)
toggle:SetMovable(true)
toggle:SetClampedToScreen(true)
-- Above action bars: Blizzard's bottom bars re-laid out over it after a vehicle
-- (Kings' Rest), and VoidBars' pet bar later sat on top of it -- both left the
-- mode untouchable mid-run. MEDIUM strata with a high frame level, NOT "HIGH":
-- HIGH put it on top of the map, talents and other windows (2026-10-25).
toggle:SetFrameStrata("MEDIUM")
toggle:SetFrameLevel(60)
pacer:SetFrameLevel(toggle:GetFrameLevel() + 5)
toggle:RegisterForDrag("RightButton")
toggle:SetScript("OnDragStart", function(self)
	if not InCombatLockdown() then self:StartMoving() end
end)
local function FinishDrag(self)
	self:StopMovingOrSizing()
	local p, _, _, x, y = self:GetPoint()
	if VoidSequencerDB then VoidSequencerDB.point = { p, x, y } end
end
toggle:SetScript("OnDragStop", function(self)
	-- a drag that outlasts the pull: the secure switch can't stop moving in combat
	-- (ADDON_ACTION_BLOCKED) -- finish it when combat ends
	if InCombatLockdown() then self.vsDragPending = true return end
	FinishDrag(self)
end)
VS.FinishToggleDrag = FinishDrag
toggle:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("|cffcc66ffVoidSequencer|r", 1, 1, 1)
	GameTooltip:AddLine("Left-click: switch ST / AoE", 0.85, 0.85, 0.85)
	GameTooltip:AddLine("Right-click + drag: move it", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Options: minimap icon or /vseq", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end)
toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- key-capture overlay, triggered by the options panel's "Set Keybind" button.
local capture = CreateFrame("Frame", nil, UIParent)
capture:SetAllPoints(UIParent)
capture:EnableKeyboard(true)
capture:SetFrameStrata("FULLSCREEN_DIALOG")
capture:Hide()
capture:SetScript("OnKeyDown", function(self, key)
	if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
		or key == "LALT" or key == "RALT" or key == "UNKNOWN" then return end
	self:Hide()
	if key ~= "ESCAPE" then VS.SetKey(key) end
end)

-- ---- Shared API for sibling files (Minimap.lua / Options.lua) ----
VS.toggle = toggle
function VS.GetKey() return VoidSequencerDB and VoidSequencerDB.key end
function VS.SetKey(key)
	if not key then return end
	if InCombatLockdown() then print("|cffcc66ffVoidSequencer|r: leave combat to rebind.") return end
	local old = VoidSequencerDB.key
	if old and old ~= key then
		ReleaseKey(old)   -- gives the old key back what was bound there before
		VoidSequencerDB.keyOrig = nil   -- the new key records its own
	end
	VoidSequencerDB.key = key
	ApplyKey(key)
	if VS.RefreshOptions then VS.RefreshOptions() end
end
function VS.CaptureKey()
	if InCombatLockdown() then
		print("|cffcc66ffVoidSequencer|r: leave combat to rebind.")
		return
	end
	capture:Show()
end
-- Master enable/disable. On -> bind the key + show the mode toggle; off -> release
-- the key (restoring its original binding) + hide the toggle. Binding changes are
-- out-of-combat only, so a mid-fight toggle defers to PLAYER_REGEN_ENABLED.
function VS.GetEnabled() return not (VoidSequencerDB and VoidSequencerDB.enabled == false) end
local function ApplyEnabled()
	-- The toggle is a secure frame: its visibility is a state driver, which also hides it
	-- in vehicles / quest override bars so Blizzard's vehicle bar has the screen (the
	-- player, 2026-10-25). Out of combat only (ApplyEnabled callers defer in combat).
	if InCombatLockdown() then pendingEnable = true return end
	if VoidSequencerDB.enabled then
		ApplyKey(VoidSequencerDB.key)
		-- one-mode specs (healers: one loop, who you hover decides) have nothing to switch
		local oneMode = DEFAULTS[currentSpec] and DEFAULTS[currentSpec].oneMode
		RegisterStateDriver(toggle, "visibility", (VoidSequencerDB.switchHidden or oneMode) and "hide"
			or "[vehicleui][overridebar] hide; show")   -- honor "switch hidden" (options / right-click)
	else
		ReleaseKey(VoidSequencerDB.key)
		RegisterStateDriver(toggle, "visibility", "hide")
	end
end
VS.ApplyEnabled = ApplyEnabled
function VS.SetEnabled(on)
	VoidSequencerDB.enabled = on and true or false
	if InCombatLockdown() then pendingEnable = true; return end
	ApplyEnabled()
end
function VS.IsAoE() return btn:GetAttribute("aoe") and true or false end

-- Priority (mash-friendly) mode: casts your best available ability each press instead of
-- stepping a timed sequence. Rebuilds the macros on toggle.
function VS.GetPriority() return VoidSequencerDB and VoidSequencerDB.priority and true or false end
function VS.SetPriority(on)
	if not VoidSequencerDB then return end
	VoidSequencerDB.priority = on and true or false
	VS.Apply()
end

-- ---------------------------------------------------------------------------
-- Talent export -- PROOF that live C_Traits access works from inside this secure
-- addon. GenerateImportString reads the CURRENT build and serialises it to the
-- same paste-able string the talent UI exports. C_Traits is "AllowedWhenUntainted",
-- and VoidSequencer is full of secure handlers -- so if this works despite our
-- taint, ImportLoadout (applying a recommended build) will too; if it's blocked,
-- we pivot to a sibling addon. Copyable box; final UX will be a panel button, this
-- slash is just the test.
-- ---------------------------------------------------------------------------
StaticPopupDialogs["VOIDSEQ_BUILDSTRING"] = {
	text = "VoidSequencer -- your current talent build (Ctrl+C to copy):",
	button1 = CLOSE,
	hasEditBox = true,
	OnShow = function(self)
		local box = self.editBox or (self.GetEditBox and self:GetEditBox())
		if box then box:SetText(VS._buildString or ""); box:HighlightText(); box:SetFocus() end
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}
function VS.ExportBuild()
	if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GenerateImportString) then
		print("|cffcc66ffVoidSequencer|r: talent API not available on this client.")
		return
	end
	local cfg = C_ClassTalents.GetActiveConfigID()
	if not cfg then print("|cffcc66ffVoidSequencer|r: no active talent config.") return end
	local ok, str = pcall(C_Traits.GenerateImportString, cfg)
	if not ok then
		print("|cffcc66ffVoidSequencer|r: talent API was BLOCKED (taint) -> " .. tostring(str))
		return
	end
	if type(str) == "string" and str ~= "" then
		VS._buildString = str
		StaticPopup_Show("VOIDSEQ_BUILDSTRING")
		print("|cffcc66ffVoidSequencer|r: read your current build OK (" .. #str .. " chars). Copy it from the box.")
	else
		print("|cffcc66ffVoidSequencer|r: got no usable string back (value: " .. tostring(str) .. ").")
	end
end
SLASH_VSBUILD1 = "/vsbuild"
SlashCmdList["VSBUILD"] = function() VS.ExportBuild() end

-- Talent IMPORT -- reuses Blizzard's OWN parser (ClassTalentImportExportMixin) so
-- the bit-format decode is guaranteed correct; we only supply the frame-context
-- methods it needs. Creates a loadout from the string (WoW auto-trims a max build
-- to the player's available points). PROOF slash; final UX is a panel button.
-- IMPORTANT: we deliberately do NOT call the talent frame's RefreshLoadoutOptions
-- ourselves. Running that Blizzard method from our (tainted) addon context taints the
-- live frame, and the talent-commit cast bar reads a SECRET value in 12.0 -> a "tainted"
-- error the moment you hit Apply (and taint could break our own rotation button too).
-- Import only ever touches a DETACHED copy of Blizzard's parser, never the live frame.
-- If your Talents window is OPEN when you import, Blizzard refreshes the dropdown itself
-- in a clean context; if it's closed, reopen it (or /reload) to see the new loadout.
-- Blizzard's import parser on a detached table (never the live talent frame).
function VS.DetachedImporter()
	local imp = CreateFromMixins(ClassTalentImportExportMixin)
	function imp:GetConfigID() return C_ClassTalents.GetActiveConfigID() end
	function imp:GetTreeInfo()
		local ci = C_Traits.GetConfigInfo(self:GetConfigID())
		return { ID = ci and ci.treeIDs and ci.treeIDs[1] }
	end
	function imp:IsInspecting() return false end
	function imp:ShowImportError(err) print("|cffcc66ffVoidSequencer|r import error: " .. tostring(err)) end
	function imp:OnTraitConfigCreateStarted() end
	return imp
end

function VS.ImportBuild(str, name)
	if InCombatLockdown() then print("|cffcc66ffVoidSequencer|r: leave combat to import talents.") return end
	if type(str) ~= "string" or str == "" then print("|cffcc66ffVoidSequencer|r: no build string.") return end
	if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_PlayerSpells") end
	if not (ClassTalentImportExportMixin and CreateFromMixins and C_ClassTalents and C_ClassTalents.GetActiveConfigID) then
		print("|cffcc66ffVoidSequencer|r: talent import API not available.")
		return
	end
	local imp = VS.DetachedImporter()
	local ok, res = pcall(imp.ImportLoadout, imp, str, name or "VoidSeq Recommended")
	if not ok then
		print("|cffcc66ffVoidSequencer|r: import call ERRORED (taint or bad reuse) -> " .. tostring(res))
	elseif res then
		print("|cffcc66ffVoidSequencer|r: build loaded -- now open your Talents, pick 'VoidSeq ...' from the loadout dropdown, and Apply.")
	else
		print("|cffcc66ffVoidSequencer|r: import returned false (see the error line above).")
	end
end
-- Talent STAGING -- the leveling-friendly way to load a build. Instead of creating a new
-- loadout (which WoW trims once and never tops up), this resets your class + spec points
-- in the CURRENT loadout and re-buys them from the build, so picking the same build again
-- after a level-up adds the new points. Points the build can't use yet (its next talents
-- are behind a gate you haven't reached) go on any open talent so none sit unspent; the
-- next re-pick past the gate moves them back into the build. Hero talents are never
-- refunded or switched; new hero points go into the hero tree you already picked.
-- Nothing is committed here: you open Talents and click Apply Changes (a clean Blizzard
-- click), so the live talent frame is never touched from addon code (see ImportBuild).
local function decodeBuild(str)
	if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_PlayerSpells") end
	if not (ClassTalentImportExportMixin and ExportUtil and C_ClassTalents and C_Traits) then
		return nil, "talent API not available."
	end
	local cfg = C_ClassTalents.GetActiveConfigID()
	local ci = cfg and C_Traits.GetConfigInfo(cfg)
	local treeID = ci and ci.treeIDs and ci.treeIDs[1]
	if not treeID then return nil, "no active talent config." end
	local imp = CreateFromMixins(ClassTalentImportExportMixin)
	local stream = ExportUtil.MakeImportDataStream(str)
	local ok, version, specID, hash = imp:ReadLoadoutHeader(stream)
	if not ok then return nil, "that build string is broken." end
	if version ~= C_Traits.GetLoadoutSerializationVersion() then return nil, "that build is from another game version." end
	if specID ~= PlayerUtil.GetCurrentSpecID() then return nil, "that build is for another spec." end
	if not imp:IsHashEmpty(hash) and not imp:HashEquals(hash, C_Traits.GetTreeHash(treeID)) then
		return nil, "that build is out of date (talent trees changed)."
	end
	local content = imp:ReadLoadoutContent(stream, treeID)
	return imp:ConvertToImportLoadoutEntryInfo(cfg, treeID, content), cfg, treeID
end

-- The hero tree a decoded build picks: name + subTreeID of its SubTreeSelection choice.
local function buildHero(entries, cfg)
	for _, e in ipairs(entries or {}) do
		local ei = e.selectionEntryID and C_Traits.GetEntryInfo(cfg, e.selectionEntryID)
		if ei and ei.subTreeID then
			local st = C_Traits.GetSubTreeInfo(cfg, ei.subTreeID)
			return st and st.name, ei.subTreeID
		end
	end
end

-- Check the current spec's recommended builds in game, for every class and spec: each
-- must decode for this talent tree and pick the hero tree it's named after. Runs when
-- the talent UI loads and on spec change; prints only problems, once per spec a session.
local checkedSpecs = {}
function VS.ValidateBuilds(force)
	if not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells")) then return end
	local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
	if not specID or (checkedSpecs[specID] and not force) then return end
	checkedSpecs[specID] = true
	local bad = {}
	for _, b in ipairs(VS.RecommendedBuilds and VS.RecommendedBuilds() or {}) do
		local entries, cfg = decodeBuild(b.build or "")
		local want = (b.name or ""):gsub("%s*%(.-%)%s*$", "")
		if not entries then
			bad[#bad + 1] = (b.name or "?") .. ": " .. tostring(cfg)
		else
			local hero = buildHero(entries, cfg)
			if not hero then
				bad[#bad + 1] = (b.name or "?") .. ": no hero talent tree in the build"
			elseif want ~= "" and hero ~= want then
				bad[#bad + 1] = (b.name or "?") .. ": the build picks " .. hero
			end
		end
	end
	for _, line in ipairs(bad) do print("|cffcc66ffVoidSequencer|r build check -- " .. line) end
	return bad
end
do
	local f, waiting = CreateFrame("Frame"), false
	local function run()
		if InCombatLockdown() then waiting = true return end   -- retried when combat ends
		waiting = false
		VS.ValidateBuilds()
	end
	f:RegisterEvent("ADDON_LOADED")
	f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:SetScript("OnEvent", function(_, e, arg)
		if e == "PLAYER_REGEN_ENABLED" then
			if waiting then run() end
			return
		end
		if e == "ADDON_LOADED" and arg ~= "Blizzard_PlayerSpells" then return end
		if e == "PLAYER_SPECIALIZATION_CHANGED" and arg ~= "player" then return end
		C_Timer.After(2, run)
	end)
end

function VS.StageBuild(str, label)
	local P = "|cffcc66ffVoidSequencer|r: "
	if InCombatLockdown() then print(P .. "leave combat to change talents.") return end
	local entries, cfg, treeID = decodeBuild(str or "")
	if not entries then print(P .. cfg) return end

	-- 1) refund class + spec points (not hero), the same as the talent frame's Reset
	local currencies = C_Traits.GetTreeCurrencyInfo(cfg, treeID, false) or {}
	for i = 1, 2 do
		local c = currencies[i]
		if c and c.traitCurrencyID then C_Traits.ResetTreeByCurrency(cfg, treeID, c.traitCurrencyID) end
	end

	-- 2) buy the build's talents. Blizzard's converter gives tiered nodes one record per
	-- entry, so total the wanted ranks per node first. Several passes so a talent whose
	-- parent comes later in tree order still gets bought once the parent is in. Hero
	-- talents: only adds points inside the hero tree you already picked, never switches it.
	local want, order = {}, {}
	for _, e in ipairs(entries) do
		local w = want[e.nodeID]
		if not w then
			w = { nodeID = e.nodeID, ranks = 0 }
			want[e.nodeID] = w
			order[#order + 1] = w
		end
		w.ranks = w.ranks + (e.ranksPurchased or 0)
		w.selectionEntryID = w.selectionEntryID or e.selectionEntryID
	end
	local heroNote, heroEntry, buildHeroEntry
	local function buy(w)
		local n = C_Traits.GetNodeInfo(cfg, w.nodeID)
		if not n or w.ranks == 0 then return false end
		if n.type == Enum.TraitNodeType.SubTreeSelection then
			-- No hero tree picked yet (first time at hero level): take the build's, so the
			-- hero points get spent -- before, every hero talent was skipped and the points
			-- sat unspent (2026-10-24). A tree you already picked is never switched.
			local cur = n.activeEntry and n.activeEntry.entryID
			if not w.selectionEntryID then return false end
			if cur and (n.ranksPurchased or 0) > 0 then
				heroEntry = cur
				if cur ~= w.selectionEntryID then heroNote, buildHeroEntry = "different", w.selectionEntryID end
				return false
			end
			if not C_Traits.CanPurchaseRank(cfg, w.nodeID, w.selectionEntryID) then return false end
			if C_Traits.SetSelection(cfg, w.nodeID, w.selectionEntryID) then
				heroNote, heroEntry = "picked", w.selectionEntryID
				return true
			end
			return false
		end
		if n.subTreeID and not n.subTreeActive then return false end   -- the other hero tree
		if n.type == Enum.TraitNodeType.Selection then
			if not w.selectionEntryID or (n.ranksPurchased or 0) > 0 then return false end
			if not C_Traits.CanPurchaseRank(cfg, w.nodeID, w.selectionEntryID) then return false end
			return C_Traits.SetSelection(cfg, w.nodeID, w.selectionEntryID) and true or false
		end
		local bought = false
		while (n.ranksPurchased or 0) < w.ranks do
			local entryID = (n.nextEntry and n.nextEntry.entryID) or (n.activeEntry and n.activeEntry.entryID)
				or (n.entryIDs and n.entryIDs[1])
			if not (entryID and C_Traits.CanPurchaseRank(cfg, w.nodeID, entryID)) then break end
			if not C_Traits.PurchaseRank(cfg, w.nodeID) then break end
			bought = true
			n = C_Traits.GetNodeInfo(cfg, w.nodeID)
		end
		return bought
	end
	local fromBuild = 0
	for _ = 1, 30 do
		local progress = false
		for _, w in ipairs(order) do
			if buy(w) then progress = true; fromBuild = fromBuild + 1 end
		end
		if not progress then break end
	end

	-- 3) leftover points: any open class/spec talent (first in tree order)
	local filler = {}
	for _ = 1, 60 do
		local progress = false
		for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
			local n = C_Traits.GetNodeInfo(cfg, nodeID)
			if n and n.isVisible and not n.subTreeID and n.type ~= Enum.TraitNodeType.SubTreeSelection
				and (n.ranksPurchased or 0) < (n.maxRanks or 0) then
				local isChoice = n.type == Enum.TraitNodeType.Selection
				local entryID = (not isChoice and n.nextEntry and n.nextEntry.entryID) or (n.entryIDs and n.entryIDs[1])
				local open = entryID and (not isChoice or (n.ranksPurchased or 0) == 0)
				if open and C_Traits.CanPurchaseRank(cfg, nodeID, entryID) then
					local ok
					if isChoice then ok = C_Traits.SetSelection(cfg, nodeID, entryID) else ok = C_Traits.PurchaseRank(cfg, nodeID) end
					if ok then
						progress = true
						local e = C_Traits.GetEntryInfo(cfg, entryID)
						local d = e and e.definitionID and C_Traits.GetDefinitionInfo(e.definitionID)
						filler[#filler + 1] = (d and d.spellID and C_Spell.GetSpellName(d.spellID)) or ("talent " .. nodeID)
						break   -- re-check from the top: points and gates just changed
					end
				end
			end
		end
		if not progress then break end
	end

	print(P .. "staged " .. (label or "the build") .. ": " .. fromBuild .. " talent pick(s) from the build"
		.. (#filler > 0 and (", " .. #filler .. " spare point(s) on " .. table.concat(filler, ", ") .. " until the build can use them") or "")
		.. ". Open Talents (N) and click |cffffd700Apply Changes|r.")
	if heroNote == "picked" then
		print(P .. "picked the build's hero talent tree and spent your hero points in it.")
	elseif heroNote == "different" then
		local function heroName(entryID)
			local ei = entryID and C_Traits.GetEntryInfo(cfg, entryID)
			local st = ei and ei.subTreeID and C_Traits.GetSubTreeInfo(cfg, ei.subTreeID)
			return (st and st.name) or "another hero tree"
		end
		local mine, theirs = heroName(heroEntry), heroName(buildHeroEntry)
		print(P .. ("you're on %s; this build is %s. Your class and spec talents were staged and your %s hero"
			.. " talents kept. For %s, use \"Switch to a build\" in VoidSequencer's options."):format(mine, theirs, mine, theirs))
	end
	-- Self-check, same for every class and spec: points still unspent after staging.
	local cur = C_Traits.GetTreeCurrencyInfo(cfg, treeID, false) or {}
	local left = ((cur[1] and cur[1].quantity) or 0) + ((cur[2] and cur[2].quantity) or 0)
	local heroLeft = 0
	if not heroEntry then   -- the build had no hero choice: read the tree you have picked
		for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
			local n = C_Traits.GetNodeInfo(cfg, nodeID)
			if n and n.type == Enum.TraitNodeType.SubTreeSelection and (n.ranksPurchased or 0) > 0 and n.activeEntry then
				heroEntry = n.activeEntry.entryID
				break
			end
		end
	end
	local ei = heroEntry and C_Traits.GetEntryInfo(cfg, heroEntry)
	local st = ei and ei.subTreeID and C_Traits.GetSubTreeInfo(cfg, ei.subTreeID)
	for _, c in ipairs(cur) do
		if st and st.traitCurrencyID and c.traitCurrencyID == st.traitCurrencyID then heroLeft = c.quantity or 0 end
	end
	if left + heroLeft > 0 then
		print(P .. ("%d class/spec and %d hero point(s) are still unspent -- spend them in Talents (N) before Apply."):format(left, heroLeft))
	end
end

-- The recommended talent builds for the player's CURRENT spec: a list of
-- { name = "<hero talent>", build = "<import string>" }, one per hero-talent choice
-- (e.g. Havoc -> Aldrachi Reaver / Fel-scarred). Empty list if none baked yet. The
-- options panel renders one button per entry.
-- A spec's builds: the M+ ones (Builds.lua, from the talent-pull sweep), then the raid
-- build of each generated rotation's players (Rotations.lua) as "<Hero> (Raid)". Keyed by
-- spec id to avoid the Frost-DK-vs-Frost-Mage name collision. Hand-curated
-- DEFAULTS[spec].builds only for specs neither sweep covered.
local function specBuilds(specID, specName)
	local out = {}
	for _, b in ipairs(VS.RecoBuilds and specID and VS.RecoBuilds[specID] or {}) do out[#out + 1] = b end
	local g = VS.GenRotations and specID and VS.GenRotations[specID]
	if g then
		local heroes = {}
		for hero, r in pairs(g) do if r.build then heroes[#heroes + 1] = hero end end
		table.sort(heroes)
		for _, hero in ipairs(heroes) do out[#out + 1] = { name = hero .. " (Raid)", build = g[hero].build } end
	end
	if #out > 0 then return out end
	local d = specName and DEFAULTS[specName]
	return (d and d.builds) or {}
end
function VS.RecommendedBuilds()
	local d = DEFAULTS[currentSpec]
	return specBuilds(currentSpecID, d and not d.gen and currentSpec or nil)
end
-- Builds for any spec of the player's class (for the switch menu).
function VS.BuildsForSpec(specID, specName)
	return specBuilds(specID, specName)
end

-- ---- One-click switch: spec + talents + hero tree ----
-- "Switch to a build" does what the player would do by hand: change spec if needed,
-- make a fresh "VS <build>" loadout from the build string, and load it with auto-apply --
-- the same C_ClassTalents.LoadConfig call Blizzard's loadout dropdown makes. None of these
-- needs a hardware click. The live talent frame is never touched (see ImportBuild), and
-- the switch won't start while the Talents tab is open (its own handler would load the new
-- loadout too). Bars, key 1 and frame clicks follow the spec change on their own.
-- Loadouts: each switch makes the build's loadout fresh (so it's always the advertised
-- build, even after the weekly list changes or a hand edit) and deletes only the one THIS
-- feature made before for that build -- recorded by config ID, never matched by name.
local SW_P = "|cffcc66ffVoidSequencer|r: "
local sw           -- the switch in progress
local swFrame = CreateFrame("Frame")

local function swSpecIndex(specID)
	local _, _, classID = UnitClass("player")
	for i = 1, (C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0) do
		local id, name = C_SpecializationInfo.GetSpecializationInfo(i)
		if id == specID then return i, name end
	end
end

local function swCurrentSpecID()
	local i = C_SpecializationInfo.GetSpecialization()
	return i and (C_SpecializationInfo.GetSpecializationInfo(i))
end

local function swDone(msg)
	if msg then print(SW_P .. msg) end
	sw = nil
	swFrame:UnregisterAllEvents()
end

-- Each wait gets a deadline; entering any new stage cancels the older one's.
local function swStage(stage, seconds, timeoutMsg)
	local s = sw
	s.stage = stage
	s.token = (s.token or 0) + 1
	if not seconds then return end
	local token = s.token
	C_Timer.After(seconds, function()
		if sw == s and s.token == token then swDone(timeoutMsg) end
	end)
end

local function swStore()
	VoidSequencerCharDB = VoidSequencerCharDB or {}
	VoidSequencerCharDB.switchLoadouts = VoidSequencerCharDB.switchLoadouts or {}
	return VoidSequencerCharDB.switchLoadouts
end

local function swFinished(configID)
	local s = sw
	C_ClassTalents.UpdateLastSelectedSavedConfigID(s.specID, configID)
	swDone(("now %s: %s. Your bars, key 1 and frame clicks follow the spec."):format(s.specName, s.label))
end

local function swLoad(configID)
	local s = sw
	if not s then return end
	local result, err = C_ClassTalents.LoadConfig(configID, true)
	if result == Enum.LoadConfigResult.Error then
		swDone("the game wouldn't load the " .. s.label .. " loadout" .. ((err and err ~= "") and (": " .. err) or "."))
		return
	end
	if result == Enum.LoadConfigResult.NoChangesNecessary then swFinished(configID) return end
	if result == Enum.LoadConfigResult.Ready then
		-- like Blizzard's Apply: commit only if changes are still staged
		if not C_Traits.ConfigHasStagedChanges(C_ClassTalents.GetActiveConfigID()) then swFinished(configID) return end
		if not C_ClassTalents.CommitConfig(configID) then
			swDone("the game wouldn't apply the " .. s.label .. " talents. Open Talents (N), pick \"" .. s.name .. "\" and Apply.")
			return
		end
	end
	-- the talent change casts: wait for the game to confirm it (or say it failed)
	s.applyID = configID
	swStage("apply", 20, "the talent change didn't confirm. Open Talents (N) to check \"" .. s.name .. "\".")
end

local function swImport()
	local s = sw
	if not s then return end
	if not C_ClassTalents.CanCreateNewConfig() then
		swDone("your loadout list for " .. s.specName .. " is full. Delete one in Talents (N), then try again.")
		return
	end
	swStage("create", 15, "the new loadout didn't arrive. Open Talents (N): if \"" .. s.name .. "\" is there, pick it and Apply.")
	local ok, res = pcall(function() local imp = VS.DetachedImporter(); return imp:ImportLoadout(s.build, s.name) end)
	if not ok or not res then
		swDone("couldn't make the " .. s.label .. " loadout" .. ((not ok) and (" (" .. tostring(res) .. ")") or " (see the error above)."))
	end
end

-- Spec is right: drop the loadout this feature made last time for this build (by ID), then
-- make it fresh.
local function swLoadout()
	local s = sw
	if not s then return end
	local store = swStore()
	local rec = store[s.key]
	local function exists(id)
		for _, c in ipairs(C_ClassTalents.GetConfigIDsBySpecID(s.specID) or {}) do
			if c == id then return true end
		end
	end
	if not (rec and rec.configID and exists(rec.configID)) then
		store[s.key] = nil   -- gone already (deleted by hand): nothing to clean up
		swImport()
		return
	end
	local old = rec.configID
	s.deleting = old
	swStage("delete")   -- cancels earlier deadlines; the fallback below checks it went
	-- the record is dropped only once the old loadout is really gone, so a failed delete
	-- never loses track of it (or fills a slot with a second copy)
	local failMsg = "couldn't remove the old \"" .. s.name .. "\" loadout. Delete it in Talents (N), then try again."
	if not C_ClassTalents.DeleteConfig(old) then swDone(failMsg) return end
	C_Timer.After(5, function()
		if sw ~= s or s.stage ~= "delete" then return end
		if exists(old) then swDone(failMsg) return end
		store[s.key] = nil
		swImport()
	end)
end

swFrame:SetScript("OnEvent", function(_, event, arg)
	local s = sw
	if not s then return end
	if event == "PLAYER_REGEN_DISABLED" then
		swDone("combat started, switch stopped. Try again after the fight.")
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		if arg == "player" and s.stage == "spec" and swCurrentSpecID() == s.specID then
			swStage("settle")
			C_Timer.After(1, function() if sw == s and s.stage == "settle" then swLoadout() end end)
		end
	elseif event == "TRAIT_CONFIG_DELETED" then
		if s.stage == "delete" and arg == s.deleting then
			swStore()[s.key] = nil
			swImport()
		end
	elseif event == "TRAIT_CONFIG_CREATED" then
		local ci = arg
		if s.stage ~= "create" or not ci or ci.name ~= s.name then return end
		swStore()[s.key] = { configID = ci.ID, build = s.build }
		local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
		if tf and tf:IsVisible() then
			-- Talents was opened mid-switch: Blizzard's handler loads a new loadout itself
			swDone(("%s: %s made -- your open Talents window is putting it on."):format(s.specName, s.label))
		elseif C_ClassTalents.IsConfigPopulated(ci.ID) then
			swLoad(ci.ID)
		else
			s.newID = ci.ID
			swStage("populate", 10, "the new loadout is still filling in. Open Talents (N), pick \"" .. s.name .. "\" and Apply.")
		end
	elseif event == "TRAIT_CONFIG_UPDATED" then
		if s.stage == "populate" and arg == s.newID then
			swLoad(s.newID)
		elseif s.stage == "apply" and (arg == s.applyID or arg == C_ClassTalents.GetActiveConfigID()) then
			swFinished(s.applyID)
		end
	elseif event == "CONFIG_COMMIT_FAILED" then
		if s.stage == "apply" then swDone("the talent change failed (moved, or got interrupted?). Click again.") end
	end
end)

function VS.SwitchToBuild(specID, b)
	if sw then print(SW_P .. "a switch is already running.") return end
	if InCombatLockdown() then print(SW_P .. "leave combat to switch.") return end
	local idx, specName = swSpecIndex(specID)
	if not idx then print(SW_P .. "that spec isn't one of yours.") return end
	if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_PlayerSpells") end
	if not (ClassTalentImportExportMixin and CreateFromMixins and C_ClassTalents.LoadConfig) then
		print(SW_P .. "the game's talent tools aren't available right now.") return
	end
	local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
	if tf and tf:IsVisible() then print(SW_P .. "close your Talents window first, then pick the build again.") return end
	local canEdit, err = C_ClassTalents.CanEditTalents()
	if not canEdit then print(SW_P .. "talents can't change right now" .. ((err and err ~= "") and (": " .. err) or ".")) return end
	local label = b.name or "Build"
	sw = { specID = specID, specName = specName, build = b.build, label = label,
		name = "VS " .. label, key = specID .. ":" .. label }
	for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_CREATED",
		"TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_DELETED", "CONFIG_COMMIT_FAILED" }) do
		swFrame:RegisterEvent(e)
	end
	if swCurrentSpecID() ~= specID then
		swStage("spec", 20, "the spec change didn't finish (moved, or got interrupted?). Click again.")
		if not C_SpecializationInfo.SetSpecialization(idx) then swDone("the game refused the spec change.") return end
		print(SW_P .. "switching to " .. specName .. "... stand still for the cast.")
	else
		swLoadout()
	end
end

-- ---- Group Finder role follows the spec ----
-- WoW keeps the role boxes from your last queue, and follower dungeons switch your spec to
-- the role you queued as -- so a Resto druid with Tank still ticked got put back in Guardian
-- (2026-10-27). On any spec change: if the new spec's role isn't ticked, tick only that one.
-- A role that's already ticked leaves your boxes alone (tank + dps on purpose stays), and
-- Leader is never touched. The Group Finder refreshes itself from LFG_ROLE_UPDATE.
local ROLE_BOX = { TANK = 1, HEALER = 2, DAMAGER = 3 }
local function MatchQueueRole()
	if not (GetLFGRoles and SetLFGRoles) then return end
	local i = C_SpecializationInfo.GetSpecialization()
	local role = i and select(5, C_SpecializationInfo.GetSpecializationInfo(i))
	local box = role and ROLE_BOX[role]
	if not box then return end
	local leader, tank, healer, dps = GetLFGRoles()
	local ticked = { tank, healer, dps }
	if ticked[box] then return end
	SetLFGRoles(leader, box == 1, box == 2, box == 3)
	print("|cffcc66ffVoidSequencer|r: Group Finder role set to "
		.. (box == 1 and "Tank" or box == 2 and "Healer" or "Damage") .. " to match your spec.")
end
do
	local f, waitCombat = CreateFrame("Frame"), false
	f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")   -- login / reload: the spec may have changed before
	f:SetScript("OnEvent", function(_, e, unit, isReload)
		if e == "PLAYER_REGEN_ENABLED" then
			if waitCombat then waitCombat = false; MatchQueueRole() end
			return
		end
		if e == "PLAYER_ENTERING_WORLD" then
			if not (unit or isReload) then return end   -- (isLogin, isReloadingUi); zoning is ignored
			C_Timer.After(3, function()
				if InCombatLockdown() then waitCombat = true else MatchQueueRole() end
			end)
			return
		end
		if unit ~= "player" then return end
		if InCombatLockdown() then waitCombat = true return end
		C_Timer.After(0.5, MatchQueueRole)
	end)
end

-- Stages the first build for the current spec onto your talents. Handy while leveling:
-- it works with the Talents window open (the options panel closes it), so it's
-- "/vsimport" then Apply Changes.
SLASH_VSIMPORT1 = "/vsimport"
SlashCmdList["VSIMPORT"] = function()
	local b = VS.RecommendedBuilds()[1]
	if b then
		VS.StageBuild(b.build, b.name)
	else
		print("|cffcc66ffVoidSequencer|r: no recommended build for " .. tostring(currentSpec) .. " yet.")
	end
end

-- ---- Rotation check: does the loaded rotation fit your talents? ----
-- Steps cast the first spell you can; one you don't have is skipped without a word, so
-- a rotation can look fine while half its steps fall through. This reports:
--   * spells the rotation uses that you don't have (not talented / not learned yet),
--   * steps where you have NONE of the spells (every press on them is wasted),
--   * talented active abilities the rotation never casts (some are utility -- fine),
--   * a hero-tree mismatch when the rotation was built for a specific one.
local function spellKnown(name)
	local info = C_Spell.GetSpellInfo(name)
	local id = info and info.spellID
	if not id then return false end
	if C_SpellBook.IsSpellKnown(id) then return true end
	local base = C_Spell.GetBaseSpell and C_Spell.GetBaseSpell(id)
	return (base and base ~= id and C_SpellBook.IsSpellKnown(base)) and true or false
end

-- Active (non-passive) abilities from talents you have, including your hero tree. Node
-- info also reflects talent picks that haven't been applied yet, so each spell must also
-- be known right now to count.
local function talentedActives()
	local out = {}
	local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
	local ci = cfg and C_Traits.GetConfigInfo(cfg)
	for _, treeID in ipairs(ci and ci.treeIDs or {}) do
		for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
			local n = C_Traits.GetNodeInfo(cfg, nodeID)
			if n and n.activeEntry and (n.activeRank or 0) > 0 and not (n.subTreeID and not n.subTreeActive) then
				local e = C_Traits.GetEntryInfo(cfg, n.activeEntry.entryID)
				local d = e and e.definitionID and C_Traits.GetDefinitionInfo(e.definitionID)
				local sid = d and d.spellID
				if sid and not C_Spell.IsSpellPassive(sid) and C_SpellBook.IsSpellKnown(sid) then
					local nm = C_Spell.GetSpellName(sid)
					if nm then out[nm] = true end
				end
			end
		end
	end
	return out
end

local function activeHeroName()
	local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
	local sub = C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec and C_ClassTalents.GetActiveHeroTalentSpec()
	local info = cfg and sub and C_Traits.GetSubTreeInfo(cfg, sub)
	return info and info.name
end

function VS.CheckRotation()
	local r = { missing = {}, dead = {}, unused = {}, total = 0, known = 0 }
	if IS_FOREVER or not VoidSequencerDB then return r end
	local used, seen = {}, {}
	local function note(name)
		name = name and strtrim(name)
		if not name or name == "" then return nil end
		used[name] = true
		if seen[name] == nil then
			seen[name] = spellKnown(name)
			r.total = r.total + 1
			if seen[name] then r.known = r.known + 1 else r.missing[#r.missing + 1] = name end
		end
		return seen[name]
	end
	-- A raw macro line ("/castsequence reset=combat A, B" or "/cast [cond] A"): check
	-- the spells it names. True if you have any of them.
	local function noteRaw(line)
		local body = line:match("^/%a+%s+(.*)$") or ""
		body = body:gsub("reset=%S+", ""):gsub("%b[]", "")
		local any = false
		for part in body:gmatch("[^,;]+") do
			local name = strtrim((part:gsub("^%s*!", "")))
			-- "null" is the castsequence's do-nothing slot (Outbreak once per combat), not a spell
			if name ~= "null" and note(name) then any = true end
		end
		return any
	end
	-- Check exactly what's loaded: the flat priority list in Priority mode, else the steps.
	for _, mode in ipairs({ "ST", "AOE" }) do
		local prio = VoidSequencerDB.priority
		for i, step in ipairs(seqOrPriority(mode) or {}) do
			local any, real = false, false
			for _, sp in ipairs(step) do
				if sp and sp ~= "" then
					real = true
					if sp:sub(1, 1) == "/" then
						if noteRaw(sp) then any = true end
					elseif note(sp) then
						any = true
					end
				end
			end
			if real and not any then
				r.dead[#r.dead + 1] = (mode == "AOE" and "AoE" or "ST") .. (prio and " priority list" or (" step " .. i))
			end
		end
	end
	local d = DEFAULTS[currentSpec]
	for _, sp in pairs(VoidSequencerDB.mods or {}) do note(sp) end
	for nm in pairs(talentedActives()) do
		if not used[nm] then r.unused[#r.unused + 1] = nm end
	end
	table.sort(r.missing); table.sort(r.unused)
	r.used = used
	r.hero, r.wantHero = activeHeroName(), d and d.hero
	r.heroMismatch = r.wantHero and r.hero and r.hero ~= r.wantHero or false
	return r
end

local function heroLine(r)
	return "rotation was built for |cffffd700" .. r.wantHero .. "|r, you're on |cffffd700" .. r.hero .. "|r"
end

-- One-line summary (options panel + chat).
function VS.RotationSummary(r)
	r = r or VS.CheckRotation()
	if r.total == 0 then return "|cff888888nothing to check|r" end
	-- Spells you don't have are left out of the button (and join it when you learn them),
	-- so missing ones are normal while leveling, not an error.
	local parts = {}
	if r.heroMismatch then parts[#parts + 1] = "|cffffaa33" .. heroLine(r) .. "|r" end
	if #r.missing == 0 then
		return "|cff55ff55OK|r -- all " .. r.total .. " spells known" .. (#parts > 0 and ("; " .. table.concat(parts, "; ")) or "")
	end
	return "|cff55ff55" .. r.known .. " of " .. r.total .. " spells|r -- the rest join as you learn them"
		.. (#parts > 0 and ("; " .. table.concat(parts, "; ")) or "")
end

function VS.PrintRotationCheck()
	local r = VS.CheckRotation()
	local P = "|cffcc66ffVoidSequencer|r rotation check (" .. specLabel(currentSpec) .. "): "
	print(P .. VS.RotationSummary(r))
	if #r.missing > 0 then print("  Not in your spellbook yet: " .. table.concat(r.missing, ", ") .. "  (left out of the button; each joins the rotation when you learn or talent it)") end
	if #r.dead > 0 then print("  Steps skipped until you learn their spell: " .. table.concat(r.dead, ", ")) end
	if r.heroMismatch then print("  Hero tree: " .. heroLine(r) .. ". Load a matching build or expect a weaker rotation.") end
	if #r.unused > 0 then print("  Talented but not in the rotation (fine if utility): " .. table.concat(r.unused, ", ")) end
	if VS.DaggerWarning then VS.DaggerWarning(r) end
end

-- Backstab (Subtlety) only works with a dagger in the MAIN hand; without one the
-- castsequence waits on it forever and key 1 looks broken. Say so.
function VS.DaggerWarning(r)
	r = r or VS.CheckRotation()
	if r.used and r.used["Backstab"] and not MainHandIsDagger() then
		print("|cffcc66ffVoidSequencer|r: |cffff5555Backstab needs a dagger in your MAIN hand|r -- "
			.. "equip one or key 1 stalls on Backstab.")
	end
end
-- ---- Healer key macros (Restoration) ----
-- Per-character macros for the keys around key 1, re-aimed out of combat whenever the
-- group or roles change: Lifebloom goes on the group's tank (in a raid: you, as top
-- raiders play it), Ironbark on whoever you hover else the tank, Nature's Cure and
-- Rebirth on whoever you hover. Macros can't look up "the tank" themselves, so the
-- tank's unit token is written into the macro text. VoidBars' suggested layout places
-- them (VoidSequencerAPI.HealMacros).
local HEAL_MACROS = {
	[105] = {   -- Restoration Druid (by spec ID: Resto Shaman shares the name)
		{ name = "VS Lifebloom", spell = "Lifebloom", aim = "tankFirst" },
		{ name = "VS Ironbark", spell = "Ironbark", aim = "hoverTank" },
		{ name = "VS Cure", spell = "Nature's Cure", aim = "hover" },
		{ name = "VS Rebirth", spell = "Rebirth", aim = "dead" },
	},
}

local function roleOf(unit)
	local r = UnitGroupRolesAssigned(unit)
	if issecretvalue and issecretvalue(r) then return nil end
	return r
end

-- Unit token of the group's tank (not you), or nil.
local function groupTank()
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local u = "raid" .. i
			if UnitExists(u) and not UnitIsUnit(u, "player") and roleOf(u) == "TANK" then return u end
		end
	elseif IsInGroup() then
		for i = 1, 4 do
			local u = "party" .. i
			if UnitExists(u) and roleOf(u) == "TANK" then return u end
		end
	end
end

local function healMacroBody(m, tank)
	local t = tank and ("[@" .. tank .. ",help,nodead]") or ""
	local cond
	if m.aim == "tankFirst" then
		cond = (IsInRaid() and "" or t) .. "[@mouseover,help,nodead][@player]"
	elseif m.aim == "hoverTank" then
		cond = "[@mouseover,help,nodead]" .. t .. "[help,nodead][@player]"
	elseif m.aim == "dead" then
		cond = "[@mouseover,help,dead][help,dead]"
	else
		cond = "[@mouseover,help,nodead][help,nodead][@player]"
	end
	return "#showtooltip " .. m.spell .. "\n/cast " .. cond .. " " .. m.spell
end

-- Create / update this spec's macros. Out of combat only (macro edits are blocked in
-- combat). Returns { [spell] = macroName } for the ones that exist.
local healMacroTank
local function UpdateHealMacros(quiet)
	local list = currentSpecID and HEAL_MACROS[currentSpecID]
	if not list or InCombatLockdown() then return {} end
	local tank = groupTank()
	local out, full = {}, false
	for _, m in ipairs(list) do
		local body = healMacroBody(m, tank)
		local idx = GetMacroIndexByName(m.name)
		if idx and idx > 0 then
			local _, _, cur = GetMacroInfo(idx)
			if cur ~= body then EditMacro(idx, m.name, "INV_MISC_QUESTIONMARK", body) end
			out[m.spell] = m.name
		else
			local _, nChar = GetNumMacros()
			if nChar < ((Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS) or MAX_CHARACTER_MACROS or 30) and CreateMacro(m.name, "INV_MISC_QUESTIONMARK", body, true) then
				out[m.spell] = m.name
			else
				full = true
			end
		end
	end
	if full and not quiet then
		print("|cffcc66ffVoidSequencer|r: your character macro list is full -- free a slot so the healer key macros (Lifebloom on the tank, ...) can be made.")
	end
	if tank ~= healMacroTank then
		healMacroTank = tank
		local nm = tank and UnitName(tank)
		if tank and not (issecretvalue and issecretvalue(nm)) and nm and not quiet then
			print("|cffcc66ffVoidSequencer|r: Lifebloom / Ironbark keys now aim at " .. nm .. " (tank).")
		end
	end
	return out
end
do
	local f, pending = CreateFrame("Frame"), false
	for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED", "PLAYER_SPECIALIZATION_CHANGED",
		"PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }) do
		f:RegisterEvent(e)
	end
	f:SetScript("OnEvent", function(_, e)
		if e == "PLAYER_REGEN_ENABLED" and not pending then return end
		if InCombatLockdown() then pending = true return end
		pending = false
		C_Timer.After(1, function()
			if InCombatLockdown() then pending = true else UpdateHealMacros() end
		end)
	end)
end

-- Small read-only API for sibling addons (VoidBars' suggested layout): which spells
-- the rotation + held modifiers already cast, so they don't need their own key.
VoidSequencerAPI = {
	RotationSpells = function() return VS.CheckRotation().used or {} end,
	IsEnabled = function() return VS.GetEnabled() end,
	SyncVehicleKey = SyncVehicleKey,   -- VoidBars calls this when it parks / restores Blizzard's bars
	-- { [spell] = macroName } for this spec's healer key macros (made / updated now; out of combat)
	HealMacros = function() return UpdateHealMacros(true) end,
}

SLASH_VSCHECK1 = "/vscheck"
SlashCmdList["VSCHECK"] = function() VS.PrintRotationCheck() end

-- After a talent change (or level-up / spec swap) re-check once things settle and say so
-- in chat only when the result changed -- no spam on every login.
local lastCheck
local function AutoCheck()
	C_Timer.After(2, function()
		local r = VS.CheckRotation()
		local s = VS.RotationSummary(r)
		if lastCheck and s ~= lastCheck then
			print("|cffcc66ffVoidSequencer|r rotation check: " .. s .. ((#r.missing + #r.dead > 0 or r.heroMismatch) and "  (/vscheck for details)" or ""))
		end
		lastCheck = s
		if VS.RefreshOptions then VS.RefreshOptions() end
	end)
end
VS.AutoCheck = AutoCheck

-- ---- Rotation-editor API (consumed by Options.lua's spell-picker) ----
-- The editor mutates the tables returned by VS.Seq() directly, then calls
-- VS.Apply() to regenerate macros and push them into the secure environment.
function VS.Seq(mode) return seqFor(mode) end       -- live SV step list
function VS.AddStep(mode) local s = seqFor(mode); s[#s + 1] = { "" } end
function VS.RemoveStep(mode, i) table.remove(seqFor(mode), i) end
function VS.MoveStep(mode, i, dir)
	local s = seqFor(mode); local j = i + dir
	if s[i] and s[j] then s[i], s[j] = s[j], s[i]; return j end
	return i
end
function VS.SetSpell(mode, stepIdx, slotIdx, spell)
	local step = seqFor(mode)[stepIdx]; if step then step[slotIdx] = spell end
end
function VS.AddSpell(mode, stepIdx, spell)
	local step = seqFor(mode)[stepIdx]; if step then step[#step + 1] = spell or "" end
end
function VS.RemoveSpell(mode, stepIdx, slotIdx)
	local step = seqFor(mode)[stepIdx]; if step then table.remove(step, slotIdx) end
end
function VS.Defaults(mode)
	if mode == "AOE" then VoidSequencerDB.seqAOE = copySeq(specDefaults().aoe)
	else VoidSequencerDB.seqST = copySeq(specDefaults().st) end
	VS.Apply()
end
-- Apply edits. Returns true if applied now, false if queued until combat ends.
function VS.Apply()
	LoadSequences()
	return not InCombatLockdown()
end
-- Current spec name (for the options-panel header).
function VS.CurrentSpec() return currentSpec end
-- Modifier ability assignments (ALT/CTRL/SHIFT -> ability), edited by the panel.
function VS.GetMod(mod) return (VoidSequencerDB.mods and VoidSequencerDB.mods[mod]) or "" end
function VS.SetMod(mod, spell)
	VoidSequencerDB.mods = VoidSequencerDB.mods or {}
	VoidSequencerDB.mods[mod] = (spell ~= nil and spell ~= "") and spell or nil
	VS.Apply()
end
-- Spells offered in the picker: union of the player's action-bar spells and any
-- spell already used in either rotation (so current picks always show), sorted.
function VS.SpellPool()
	local set, list = {}, {}
	local function add(nm) if nm and nm ~= "" and not set[nm] then set[nm] = true; list[#list + 1] = nm end end
	for slot = 1, 120 do
		local atype, id = GetActionInfo(slot)
		if atype == "spell" and id and C_Spell and C_Spell.GetSpellName then add(C_Spell.GetSpellName(id)) end
	end
	for _, m in ipairs({ "ST", "AOE" }) do
		for _, step in ipairs(seqFor(m) or {}) do
			for _, sp in ipairs(step) do add(sp) end
		end
	end
	table.sort(list)
	return list
end

-- ---------------------------------------------------------------------------
-- Boot.
-- ---------------------------------------------------------------------------
-- Detect the current spec and (re)seed its sequences, then push them into the
-- secure env. Runs on login AND on live spec change, so swapping spec swaps the
-- rotation with NO /reload -- fixes the bug where switching Resto -> Guardian kept
-- firing the leftover heal sequence. Re-seeds only when the spec actually changed
-- (or version bump / first run), so a same-spec /reload keeps your edits.
local function ApplySpec()
	if not VoidSequencerDB then return end
	VS.unsupportedSpec = nil
	currentSpec = detectSpec()
	local specDef = DEFAULTS[currentSpec]
	if specDef then
		if VoidSequencerDB.seededSpec ~= currentSpec
			or VoidSequencerDB.defaultsVer ~= DEFAULTS_VER
			or (VoidSequencerDB.seededRev or 0) ~= (specDef.rev or 0)
			or not VoidSequencerDB.seqST then
			VoidSequencerDB.seqST  = copySeq(specDef.st)
			VoidSequencerDB.seqAOE = copySeq(specDef.aoe)
			VoidSequencerDB.seededSpec = currentSpec
			VoidSequencerDB.defaultsVer = DEFAULTS_VER
			VoidSequencerDB.seededRev = specDef.rev or 0
			-- Tanks live in AoE (M+ trash is the whole game), so default a tank spec
			-- to AoE mode on (re)seed; DPS/heal default to ST. You can still toggle
			-- per-fight (e.g. flip to ST on a lone boss).
			local si = GetSpecialization and GetSpecialization()
			local role = si and GetSpecializationRole and GetSpecializationRole(si)
			local TANKS = { Guardian = true, Blood = true, Protection = true, Brewmaster = true, Vengeance = true }
			VoidSequencerDB.aoe = (role == "TANK") or (TANKS[currentSpec] == true)
			-- seed this spec's modifier assignments (ALT/CTRL/SHIFT -> ability); the
			-- options-panel pickers edit these.
			VoidSequencerDB.mods = {
				alt   = specDef.mods and specDef.mods.alt,
				ctrl  = specDef.mods and specDef.mods.ctrl,
				shift = specDef.mods and specDef.mods.shift,
			}
		end
	else
		-- no defaults for this spec yet: don't seed wrong-class spells.
		VS.unsupportedSpec = currentSpec   -- the real name, for the spec-change message
		currentSpec = DEFAULT_SPEC
		if not VoidSequencerDB.seqST then VoidSequencerDB.seqST = { { "" } } end
		if not VoidSequencerDB.seqAOE then VoidSequencerDB.seqAOE = { { "" } } end
	end
	LoadSequences()
end

-- Pick the rotation for the current spec (nil = automatic: tuned, else your hero tree's).
-- Saved per character and spec; loads at once out of combat.
function VS.SetRotationPick(key)
	local i = GetSpecialization and GetSpecialization()
	local specID = i and GetSpecializationInfo(i)
	if not specID then return end
	if InCombatLockdown() then print("|cffcc66ffVoidSequencer|r: leave combat to change the rotation.") return end
	VoidSequencerCharDB = VoidSequencerCharDB or {}
	VoidSequencerCharDB.rotPick = VoidSequencerCharDB.rotPick or {}
	VoidSequencerCharDB.rotPick[specID] = key
	ApplySpec()
	PushMode()
	ApplyEnabled()
	print("|cff00c7ffVoidSequencer|r loaded the |cffffd700" .. specLabel(currentSpec) .. "|r rotation.")
	if VS.RefreshOptions then VS.RefreshOptions() end
end

-- Key 1 belongs to VoidSequencer, so its action slot stays EMPTY. After a spec or talent
-- change the game drops newly learned spells into the first empty slot, which is slot 1
-- (the user, 2026-10-28: "that needs to be corrected every time"). SPELL_PUSHED_TO_ACTIONBAR
-- names the slot it used; a key-1 slot (main page 1, or a form / stealth page 7-10) is
-- emptied again. The spell stays in the spellbook. PickupAction is protected in combat,
-- so it waits for combat to end; never while something is on the cursor (a drag).
local KEY1_SLOTS = { [1] = true, [73] = true, [85] = true, [97] = true, [109] = true }
local pushed = {}
local function ClearPushedKey1()
	if InCombatLockdown() or GetCursorInfo() then return end
	for slot, spellID in pairs(pushed) do
		pushed[slot] = nil
		local t, id = GetActionInfo(slot)
		if t == "spell" and id == spellID then
			PickupAction(slot)
			ClearCursor()
			print("|cff00c7ffVoidSequencer|r: took " .. (C_Spell.GetSpellName(spellID) or "a new spell")
				.. " off key 1 (the game put it there). It's in your spellbook.")
		end
	end
end
local pushWatch = CreateFrame("Frame")
pushWatch:RegisterEvent("SPELL_PUSHED_TO_ACTIONBAR")
pushWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
pushWatch:SetScript("OnEvent", function(_, event, spellID, slot)
	if event == "SPELL_PUSHED_TO_ACTIONBAR" then
		if not (KEY1_SLOTS[slot] and VS.GetEnabled()) then return end
		pushed[slot] = spellID
		C_Timer.After(0.5, ClearPushedKey1)   -- let the game finish placing it first
	elseif next(pushed) then
		C_Timer.After(0.5, ClearPushedKey1)
	end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("TRAIT_CONFIG_UPDATED")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("SPELLS_CHANGED")
local lastDaggerMH, spellsPending
ev:SetScript("OnEvent", function(_, event, unit)
	if event == "SPELLS_CHANGED" then
		-- new / lost spells (level-up, talents): castsequences re-trimmed (trimSequence);
		-- debounced, and a no-op when the macros come out the same
		if spellsPending or not (VoidSequencerDB and VoidSequencerDB.seqST) then return end
		spellsPending = true
		C_Timer.After(1, function() spellsPending = nil; LoadSequences(true) end)
		return
	end
	if event == "PLAYER_EQUIPMENT_CHANGED" then
		-- main-hand swap between a dagger and another weapon: rebuild (NO_DAGGER_MH)
		if unit ~= (INVSLOT_MAINHAND or 16) or not VoidSequencerDB then return end
		local d = MainHandIsDagger()
		if d ~= lastDaggerMH then
			lastDaggerMH = d; LoadSequences()
			if not d then VS.DaggerWarning() end
		end
		return
	end
	if event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_LEVEL_UP" then
		AutoCheck()
		-- a talent change can switch hero tree, and with it the rotation variant
		-- (Unholy -> Unholy:San'layn): load it like a spec change, out of combat
		if event == "TRAIT_CONFIG_UPDATED" and VoidSequencerDB and not InCombatLockdown()
			and detectSpec() ~= currentSpec then
			ApplySpec()
			PushMode()
			ApplyEnabled()
			if VS.unsupportedSpec then
				-- same wording as a spec change: a spec without a built-in rotation loads
				-- nothing (it printed "loaded the Unholy rotation" on a Hunter, 2026-10-29)
				print("|cff00c7ffVoidSequencer|r has no built-in rotation for |cffffd700"
					.. VS.unsupportedSpec .. "|r yet. Build one in the editor (/vseq).")
			else
				print("|cff00c7ffVoidSequencer|r loaded the |cffffd700" .. specLabel(currentSpec) .. "|r rotation (hero tree changed).")
			end
		end
		if event == "PLAYER_LEVEL_UP" then
			-- Leveling: a saved loadout never gains points, so point at /vsimport (which
			-- re-lays the build onto your current talents) when there are points to spend.
			C_Timer.After(3, function()
				local b = VS.RecommendedBuilds()[1]
				local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
				local ci = cfg and C_Traits.GetConfigInfo(cfg)
				local treeID = ci and ci.treeIDs and ci.treeIDs[1]
				if not (b and treeID) then return end
				local unspent = 0
				for _, c in ipairs(C_Traits.GetTreeCurrencyInfo(cfg, treeID, false) or {}) do
					unspent = unspent + (c.quantity or 0)
				end
				if unspent > 0 then
					print("|cffcc66ffVoidSequencer|r: " .. unspent .. " new talent point(s). Open Talents (N), type |cffffd700/vsimport|r, then Apply Changes ("
						.. (b.name or "recommended build") .. ").")
				end
			end)
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		VoidSequencerDB = VoidSequencerDB or {}
		local newKey = VoidSequencerDB.key == nil
		for k, v in pairs(DB_DEFAULTS) do
			if VoidSequencerDB[k] == nil then VoidSequencerDB[k] = v end
		end
		if newKey and VoidSequencerDB.enabled then
			print("|cff00c7ffVoidSequencer|r is on key |cffffd7001|r. Change it in /vseq.")
		end
		VoidSequencerDB.log = nil   -- leftovers of removed debug logs
		if VoidSequencerCharDB then VoidSequencerCharDB.castlog, VoidSequencerCharDB.errlog = nil, nil end
		-- Seed the sequences for the character's CURRENT spec (see ApplySpec). This
		-- now also re-runs live on PLAYER_SPECIALIZATION_CHANGED, so swapping spec
		-- no longer needs a /reload.
		ApplySpec()
		AutoCheck()   -- first run only records the baseline (spell data needs a moment)
		-- restore saved mode + position. A /reload in combat logs in under lockdown: the
		-- secure attribute / position wait for combat to end (ADDON_ACTION_BLOCKED, 2026-10-25).
		PushMode()
		if not InCombatLockdown() then
			local p = VoidSequencerDB.point or { "CENTER", 0, -150 }
			toggle:ClearAllPoints()
			toggle:SetPoint(p[1], UIParent, p[1], p[2], p[3])
		else
			pendingPlace = true   -- placed when combat ends
		end
		ApplyEnabled()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- Live spec swap (e.g. Resto heal <-> Guardian tank): re-detect and load the
		-- new spec's rotation so the one-button stops firing the old spec's sequence.
		-- The event can fire for other units; only act on the player. A visible
		-- confirmation means the swap is never silent (the bug was you couldn't tell
		-- the heal sequence was still loaded while tanking).
		if unit == "player" or unit == nil then
			ApplySpec()
			-- ApplySpec set the role-default mode (tank -> AoE); push it to the button.
			local aoe = PushMode()
			ApplyEnabled()   -- one-mode specs (healers) hide the ST/AoE switch, others show it
			local oneMode = DEFAULTS[currentSpec] and DEFAULTS[currentSpec].oneMode
			if VS.unsupportedSpec then
				-- "loaded the Unholy rotation" on a Demonology warlock read as wrong
				-- spells being loaded (2026-10-25); nothing is seeded for these specs
				print("|cff00c7ffVoidSequencer|r has no built-in rotation for |cffffd700"
					.. VS.unsupportedSpec .. "|r yet. Build one in the editor (/vseq).")
			else
				print("|cff00c7ffVoidSequencer|r loaded the |cffffd700" .. specLabel(currentSpec)
					.. "|r rotation (" .. (oneMode and "one mode: who you hover decides" or (aoe and "AoE" or "ST") .. " mode") .. ").")
			end
			AutoCheck()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingMode then pendingMode = nil; PushMode() end
		if pendingPlace then
			pendingPlace = nil
			local p = VoidSequencerDB.point or { "CENTER", 0, -150 }
			toggle:ClearAllPoints()
			toggle:SetPoint(p[1], UIParent, p[1], p[2], p[3])
		end
		if toggle.vsDragPending then toggle.vsDragPending = nil; VS.FinishToggleDrag(toggle) end
		if pendingEnable then pendingEnable = nil; ApplyEnabled() end
		if pendingKey then local k = pendingKey; pendingKey = nil; ApplyKey(k) end
		-- flush any rotation edits made during combat
		if seqDirty then seqDirty = false; LoadSequences() end
	end
end)

