# VoidSequencer Changelog

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
