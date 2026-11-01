# VoidSequencer

**One key, your whole rotation: built from what the best players actually press.**

VoidSequencer puts your spec's rotation on a single key. Every spec and every hero tree has one, built from the casts of top Mythic players. Pick a recommended build, press 1, and play. You still press the key for every cast; VoidSequencer only picks which spell.

> **Beta.** Every spec has a rotation, but most were generated from top players' fights and haven't been tested in game by us yet. They're labelled **Top players (beta)** in the rotation picker. The ones built and tested by hand are labelled **Tuned**. Tell us how yours plays and it moves up.

---

## Features

### A Rotation for Every Spec and Hero Tree
- **All 40 specs** — tanks and healers included, with a rotation for each hero tree.
- **Built from real play** — how often top players press each spell, in what order, with their cooldowns.
- **Cooldowns wait for their setup** — when top players always set a cooldown up first (Call Dreadstalkers before Summon Demonic Tyrant, Meteor before Combustion), it waits for that setup to land.
- **Rotation picker** — the automatic choice for your hero tree, or any tuned or generated rotation for your spec.
- **Healers** — one loop: heals land on whoever you hover, damage on a hovered enemy, and with nothing hovered the heal goes on you.
- **Single Target / AoE switch** — flip it for packs; your spec and hero tree changes are followed on their own.

### Grows With You While Leveling
- **No dead presses** — spells you haven't learned or talented yet are left out of the key.
- **New spells join by themselves** — the moment you learn one, it's in the rotation.
- **A start for brand-new characters** — with only a couple of the rotation's spells known, your class's basic attacks fill in until the real rotation takes over.

### One-Click Talent Builds
- **Builds for every spec and hero tree** — from the top Mythic+ players and the top raid players.
- **Switch to a build** — one click changes spec (if needed), talents and hero tree.
- **Put a build on your current talents** — it's laid onto your talent tree; open Talents and click Apply.
- **Leveling** — pick the build again after a level-up to spend the new points.

### Your Key, Your Call
- **Enable toggle** — switch it off and key 1 goes back to whatever you had bound there.
- **Rotation editor** — change any step with a spell picker. No macro syntax.
- **Modifier casts** — hold Alt, Ctrl or Shift while pressing your key to fire a spell you choose (a cooldown, a defensive, an external).
- **Rotation check** — shows how many of the rotation's spells you have, like "6 of 9 spells, the rest join as you learn them".

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vseq` | Open the options (also `/voidsequencer`) |
| `/vsimport` | Put your spec's top recommended build on your talents, then click Apply in Talents |
| `/vscheck` | Rotation check: which of the rotation's spells you have |
| `/vsbuild` | Show your current talent build string to copy |

---

## Getting Started
1. Install with the CurseForge app, or copy the `VoidSequencer` folder into
   `World of Warcraft/_retail_/Interface/AddOns/`.
2. Restart WoW or `/reload`.
3. Your rotation is already on **key 1**. Open `/vseq` to pick a recommended build or another rotation, then press 1.

---

## Is This Allowed?

Yes. VoidSequencer is a one-button macro: a secure button whose macro is rebuilt out of combat and casts one spell per key press. Nothing casts without you pressing the key, there's no input simulation, and no combat logic runs on its own. It only takes away the "which button next" part.

---

## Good to Know
- **English game client only** — rotations cast spells by their English names.
- **Where the rotations come from** — top players' fights and Blizzard's own game data, refreshed when talent trees change.
- **Your settings** — saved per character: your key, your rotation picks and any edits.

---

## Compatibility
- **WoW 12.1** (Midnight Season 2)
- Works on its own; no other addon needed.

---

*Part of the Void addon family by Vede · MIT licensed · [Source & bug reports](https://github.com/bughatti/voidsequencer) · [All Void addons](https://www.curseforge.com/members/bughatti/projects) · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
