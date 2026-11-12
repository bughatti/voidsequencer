# VoidSequencer Changelog

## 1.0.13 — 2026-11-12

- **Fixed: a side of a box could be missing**, e.g. the right line of the recipes box and its buttons when the game window is an odd number of pixels wide. Every Void box now always shows all four border lines.

## 1.0.12 — 2026-11-12

- **The rotation test windows can be dragged** and stay where you put them, even after a restart.
- **Void hub button:** left-click opens one panel with all your Void addons by name, grouped, each with its own on/off switches (it replaces the ring of icons), with a background slider. The hub's info window now stays where you put it.

## 1.0.11

- **WoW Forever:** **Defaults** no longer loads the Unholy rotation for a class without a built-in one (it says so instead), and the retail top-player rotation picker is hidden there.

## 1.0.10

- **Fixed: box borders missing a side.** Depending on where a window sat on screen, its left, right or bottom line could vanish. Borders are now exactly one screen pixel and can't round away.

## 1.0.9 (Beta) — 2026-11-08

- **WoW Forever rogue: the rotation key no longer puts you in Stealth.** Out of combat it used to cast Stealth first; now Stealth stays on your own key. When you are stealthed, the key still opens with Ambush or Cheap Shot, without an auto-attack swing breaking Stealth first.

## 1.0.8 (Beta) — 2026-11-08

- **Put the rotation on the mouse wheel.** Set Keybind (in `/vseq`) now takes the mouse wheel up or down (each notch is one press), mouse buttons 3, 4 and 5 (the wheel click is 3), and Alt / Ctrl / Shift combinations, not only plain keys. A prompt shows while it waits, and the options name the binding the way the game does ("Mouse Wheel Down"). Thanks to 777marc for asking.

## 1.0.7 (Beta) — 2026-11-07

- **WoW Forever rogue: no more getting stuck on a finisher.** When both Sinister Strikes were dodged or parried, the rotation reached Slice and Dice with no combo points and stayed there ("That ability requires combo points") until you changed target, which on a boss meant most of the fight. Key 1 now also throws a plain Sinister Strike regularly, so a combo point always comes and the finisher goes out. With swords and daggers.

## 1.0.6 (Beta) — 2026-11-07

- **WoW Forever rogue with a dagger: Ambush, Backstab and Eviscerate.** From Stealth, key 1 opens with Ambush (Cheap Shot when it can't). In the fight the order is Backstab, Backstab, Slice and Dice, Backstab, Backstab, Eviscerate (the sword order with Backstab in it); when you're in front, Sinister Strike, Sinister Strike, Eviscerate runs instead, so you still build and finish. With a sword nothing changes, and a weapon swap switches the rotation.
- **WoW Forever rogue: Shank** (the level-24 off-hand strike: 5 Energy, gives 15 back, can't miss) is in all three modes, on its own step so its cooldown never blocks the rest.
- **WoW Forever talents:** the talent picker offers a build for your class on Forever too (the rogue's Combat leveling build), laid onto your current talents node by node.
- **Settings asked for in combat open when combat ends** instead of failing.
- **Safer after a /reload mid-fight:** all of key 1's setup runs while the UI loads, before the game's combat lock; if it ever loads under the lock, it finishes the moment combat ends instead of staying dead.

## 1.0.5 (Beta) — 2026-11-03

- **Test my rotation.** A new button in the options (or `/vstest`): hit a training dummy for 2-3 minutes and see each spell's casts per minute next to the top players' for your spec and hero tree, with what the game refused (out of range, not ready) and your damage per second. Copy the short report into our Discord to help tune the rotations. It reads only your own casts; the report never has your character name or realm. English game client for now.
- **Feral (Druid of the Claw) rebuilt for single target:** four builders before every finisher (a cast sequence, so mashing can't skip one), and Incarnation / Berserk / Tiger's Fury lead every step. Before, single target skipped both big cooldowns on the Mythic+ build and spent finishers at 1-2 combo points.

## 1.0.4 (Beta) — 2026-11-02

### Changed
- **Unholy (San'layn) single target hits harder.** Festering Strike / Festering Scythe now has a step of its own, as in AoE, so it's cast closer to how often the top players do, feeding more Vampiric Strikes and Necrotic Coils. On a training dummy: 85K -> 109K damage per second.
- **Void hub:** right-click it for **Copy settings from...** to take another character's settings for your Void addons.

## 1.0.3 (Beta) — 2026-11-02

### Changed
- **Void hub icon:** your Void addons now pop out in rings around the hub icon, fanning away from the minimap, instead of one long column. The pop-up also works while another addon moves or fades the minimap.

## 1.0.2 (Beta) — 2026-11-01

### Changed
- **Void hub icon:** the list of Void addons is up to date (adds VoidGather and VoidSweep, refreshed descriptions).

## 1.0.1 (Beta) — 2026-10-31

### Fixed
- **Your edits are kept per spec.** Switching spec (or rotation) used to replace your edited sequence with the new spec's defaults, so switching back lost your edits. Each spec's edits now come back when you return to it.
- **Key 1's action slot is only cleared while VoidSequencer is on and bound to key 1.** If you moved VoidSequencer to another key or turned it off, a new spell the game placed in slot 1 is left alone.
- **WoW Forever Paladin:** the seal is recast at least once every fight (it only came back after 28 seconds without pressing the key).

## 1.0.0 (Beta) — 2026-10-30

First public release.

### Added
- **A rotation for every spec and hero tree.** All 40 specs, built from the top Mythic players' casts. Hand-built and tested ones are labelled **Tuned**; the rest are **Top players (beta)**.
- **Rotation picker** in the options: automatic for your hero tree, or any tuned or generated rotation for your spec.
- **Cooldowns wait for their setup.** When top players always set a cooldown up first (Call Dreadstalkers before Summon Demonic Tyrant, Meteor before Combustion), it waits for that setup to land. Specs with long casts get each cooldown twice per cycle so it isn't missed.
- **Grows with you while leveling.** Spells you haven't learned are left out of the key and join the moment you learn them; brand-new characters start with their class's basic attacks.
- **Builds for every hero tree**, from top Mythic+ players and top raid players.
- **Beast Mastery Hunter** rotation.

### Changed
- **Key 1 by default.** A new character has the rotation on key 1 right away; turning VoidSequencer off gives key 1 back.
- **Rotation check** reads "6 of 9 spells, the rest join as you learn them" instead of a warning.
- **Channels:** mashing your key during Mind Flay or Void Torrent no longer skips ahead.

### Removed
- **Priority mode.** A key press makes one cast attempt, so it could only ever try its first spell.

### Fixed
- A character with no spec yet (level 1-9) no longer gets another class's rotation.
- Changing your rotation key frees the old key.
- The Single Target / AoE switch is placed correctly after a reload in combat.
- A Restoration Shaman no longer loads the Restoration Druid rotation.

## 2026-10-26 (rolled into 1.0.0)

### Changed
- **Subtlety Rogue rebuilt for level 90 (12.1.5, Trickster), rev 6.** It's built from the top Mythic players' actual cast order and tested on a target dummy, single target and 3-target AoE:
  - **Builders and finishers about 1:1.** Backstab (Shadowstrike in Stealth or Shadow Dance) → Eviscerate. In AoE, Shuriken Storm → Eviscerate / Black Powder.
  - **Shadowstrike has its own sequence** for Stealth and Dance (`[stealth][bonusbar:1]`). It isn't an override of Backstab.
  - **Shadow Dance and Secret Technique share a step.** Dance is never cast while one is already running.
  - **Secret Technique and Goremaw's Bite get 3 and 2 turns per cycle,** so they go out soon after they're ready. Shadow Blades rides off the GCD on the core steps.
  - **A builder step clears the stall** where the sequence waited on Eviscerate at 0 combo points after Secret Technique spent them.

### Added
- **Dagger warning.** Backstab needs a dagger in the main hand. `/vscheck` and a main-hand swap now say so, because otherwise key 1 just stalls on Backstab.

## 0.5.0 — 2026-07-20

### Added
- **Cadence glow.** An optional green pulse on the rotation button that lights up the
  instant a press will land (you're off the global cooldown) — tap your key in rhythm
  with it so fast mashing can't skip steps. Toggle it in the options panel.

### Changed
- **Shadow Priest (Voidweaver) rotation overhaul.** Rebuilt and tuned both the
  single-target and AoE sequences — an instant-heavy core (Shadow Word: Madness maxed,
  Void Blast fired through Entropic Rift), Tentacle Slam spreading DoTs so every nuke
  cleaves via Psychic Link, and a fallback on every line so no press is wasted.
  Validated live across multiple +10 dungeons.

### Removed
- Internal press-rate / debug instrumentation that was used during rotation tuning.

## 0.4.0 — 2026-07-04

### Added
- **One-click recommended talent builds for every spec.** The options panel now has a
  dropdown of recommended builds for your current spec — one per hero talent (e.g.
  Aldrachi Reaver / Fel-Scarred), split into Raid and M+ where the best build differs.
  Pick one and it creates a saved loadout in your talent UI; open Talents, select it,
  and Apply. Covers all 40 specs across every class and role. At lower level WoW trims
  the build to the points you can afford, so it's safe to load while leveling and
  re-load as you gain levels.
- **Priority mode (mash-friendly).** A new toggle at the top of the options. Instead of
  stepping through a timed sequence, it casts your **best available ability each press** —
  so mashing the key as fast as you want can't scramble the order (there's no step counter
  to race). Off = the classic timed sequence. Great if you found the sequencer punished
  fast or uneven presses.
- **Windwalker Monk profile**, with Expel Harm woven in for self-sustain while leveling.

### Fixed
- **Talent import no longer taints the UI.** Import uses a detached copy of Blizzard's
  own loadout parser and never touches the live talent frame, so applying a build won't
  trigger the "tainted" cast-bar error (and can't leak taint into the rotation button).
  Have your Talents window handy after importing — the new loadout appears in its
  dropdown without a reload.
- **Unholy rotation: cooldowns and builders no longer get skipped.** Removed the "lone"
  cooldown steps (Soul Reaper, Dark Transformation) that cast nothing when the ability
  was down — on a real log they were dropping Soul Reaper and Festering Strike to zero.
  Every step now has a damage fallback, so no press is ever wasted.
- **Debug logger only records in combat**, so it no longer fills your SavedVariables with
  fishing/profession casts.

## 0.3.0 — 2026-07-04

### Added
- **Auto spec-swap.** VoidSequencer now detects a live spec change and loads that
  spec's rotation instantly — no `/reload` needed (it used to keep the old spec's
  sequence, e.g. firing the heal rotation while you tanked). Shows a chat line on
  swap, and tank specs default to AoE mode.
- **Modifier ability pickers.** The options panel now has ALT / CTRL / SHIFT
  dropdowns to bind any ability per spec, replacing the old hardcoded (and broken)
  Army/Death-Pact checkboxes. The panel is spec-aware, and heal externals keep
  their mouseover targeting.
- **Guardian (bear tank) profile** rebuilt to match how the top M+ Guardian bears play —
  Sundering Roar + Incarnation auto-fire; Thrash-weighted priority stacks for real
  AoE threat. SHIFT → Survival Instincts by default.

### Fixed
- Options panel showed DK abilities (Army/Death Pact) on non-DK specs.

## 0.2.0 — 2026-06-27

### Unholy DK rotation rebuilt to match top players (validated live)

Rebuilt the Unholy ST + AoE default sequences to match how the top Unholy DKs
play (~217k DPS reference). A live test
exposed three rotation-killing flaws in the old default, all now fixed:

- **Scourge Strike was buried** under 5 lone-cooldown steps that bounce — it is
  the spec's spine and was barely firing (~4/min vs the top players' ~30/min).
- **Death Coil / Necrotic Coil was absent** from the AoE sequence entirely
  (0 casts), so on a single-target boss in AoE mode all runic power went into
  weak Epidemics instead.
- **Outbreak led an AoE step** (the spell has no cooldown, so it fired every
  cycle), re-applying the disease ~32× a fight when top players cast it once.

Fixes: ST filler is now Scourge-first (falls through to Death Coil when
rune-starved) with two Death-Coil-first steps to dump runic power; AoE is
Epidemic RP-dump + Scourge cleave; Outbreak is demoted to the deepest fallback in
one step (fires only when rune AND RP are both starved, so the disease still
self-heals if it ever drops, without the spam). `DEFAULTS_VER` bumped 3 -> 4 to
force a one-time per-character re-seed.

**Live validation — Unholy DK, Sporefall Heroic, 2026-06-27 (per-minute cast rates):**

| Metric | Before (old macro) | After (new macro) |
|---|---|---|
| Scourge Strike | 4.3/min | 17-20/min (~5x) |
| Outbreak | 6.6/min (~32/fight) | 0 |
| Death Coil + Necrotic Coil (ST mode) | 0 | 75/fight (~16/min) |
| Festering Strike | over-capped (~5/min) | rebalanced (~3/min) |

On a clean single-target boss (Fallen-King Salhadaar) in ST mode the rebuild
reproduced the top-DK cast profile almost exactly — Scourge 94, Death + Necrotic
Coil 75, Epidemic 0, Outbreak 0, vs a top DK's Scourge 135 / DC+NC 80.
RP-spender rate landed within ~10% of the world's best Unholy DK. Dragons
(Vaelgor & Ezzorak, mixed ST/AoE) parsed 66 overall. Remaining gap to top is
execution (burst stacking, pre-pot), not rotation shape — the macro now does the
right thing on every press.

## 0.1.0

Initial release: secure one-button rotation sequencer. A
SecureActionButton whose macrotext is rebuilt out of combat from per-spec,
per-mode priority-stack sequences (WoW casts the first castable spell in each
step, the rest are fallbacks). Guided spell-picker editor (no macro syntax),
ST/AoE mode toggle, by-hand cooldown modifiers (Army on Alt, Death Pact on Ctrl).
Ships defaults for Unholy DK, Guardian Druid, and Havoc DH.
