# 31. What makes a skill or item usable is its type, not its occasion flags

Date: 2026-08-05

## Status

Accepted

## Context

The RPG2000 runtime decided whether a skill or item could be used from a menu by
reading the row's "usable in field / usable in battle" flags:

```ruby
sk && sk.type == SKILL_NORMAL && sk.occasion_field && sk.scope >= 2   # field
sk && sk.type == SKILL_NORMAL && battle_occasion?(sk) && ...          # battle
```

Both halves of that are wrong, and the result was stark. Teaching a test bed's
party every skill in its database and handing it one of every item, then asking
what the menus offer:

| | Nepheshel 2.06 | mtf-meido-action |
|---|---|---|
| skills in the database | 306 | 134 |
| **battle skill menu** | **0** | **0** |
| field skill menu | 30 | 2 |
| items in the database | 1200 | 100 |
| **battle item menu** | **0** | **0** |
| field item menu | 41 | 14 |

**Neither game could use a single skill or item in a fight.** Every fixture check
passed throughout, because the fixtures were built to the same wrong model.

Three separate mistakes produced that.

### The occasion flags gate switch skills only

`occasion_field` (chunk 18, default true) and `occasion_battle` (chunk 19,
default false) are not general "where can this be used" flags. RPG_RT reads them
in one place — the `Type_switch` arm of `Algo::IsSkillUsable` — and the RPG2000
editor only shows the 使用可能な場面 checkboxes for a スイッチ skill at all.
Everything else is decided by type, scope and effect.

The bytes say the same thing, and say it precisely. Chunk presence across the two
test beds:

- Nepheshel writes chunk 18 for **6** of its 306 skills and chunk 19 for **12** —
  and those 12 are *exactly* its 12 switch skills, the 6 being the subset that is
  battle-only.
- mtf-meido-action, which has **no** switch skill, writes neither chunk for any
  of its 134 skills.

So on real data `occasion_battle` was almost always the default `false`, and
gating on it emptied the battle menu.

### RPG2003 files skills under numbered categories

liblcf's `Skill::Type` runs `normal=0, teleport=1, escape=2, switch=3,
subskill=4` — and 2003 numbers each custom battle command from 4 up, putting the
category id in the same field. `type == SKILL_NORMAL` therefore rejects an
ordinary skill for the sole reason that a 2003 game sorted it into a menu.
That is **57 of mtf-meido-action's 134 skills** (43%), including every one of its
healing lines — Heal, Recovery, Cure and Raise are all category 5 — and its
elemental attack lines.

### Item types 9 and 10 were read one place out

liblcf's `Item::Type` ends `material=8, special=9, switch=10`. This build had
`ITEM_SWITCH = 9` and no notion of a special item, so the two were swapped.
Nepheshel settles it from the bytes:

- its **14 type-9 items** each carry a *distinct* `skill_id` naming a skill of
  the same name (item 天使の翼 → skill 天使の翼, 火炎玉 → 火炎玉) with
  `switch_id` left at the default 1;
- its **41 type-10 items** are the mirror image — 41 distinct `switch_id`s, with
  `skill_id` left at the default.

Reading 9 as "switch" made all 14 special items flip switch **1**, a switch they
never named, and left the 41 real switch items unrecognised and absent from the
bag.

A fourth, quieter mistake sat underneath: the runtime asked every item for
`occasion_field`, a field **no real item row has**. RPG2000 gives an item three
occasion fields with three different jobs (`occasion_field1` bars battle use,
`occasion_field2` and `occasion_battle` are the switch item's own pair), so the
lookup fell through to its "no flag, assume usable" default on every genuine item
and the gate never once fired. Only the fixtures, which did define that name,
ever exercised it — which is why `docs/TODO.md` claimed a behaviour that never
happened on real data.

## Decision

Decide usability the way RPG_RT does, ported from a reference
implementation's own skill/item usability logic (not independently
confirmed against genuine RPG_RT under wine):

- **Skills.** Escape and teleport are never usable in battle; a switch skill
  consults `occasion_battle` / `occasion_field`; anything else (normal or a 2003
  subskill category) is always usable in battle, and usable in the field when its
  scope reaches an ally and it does something there — changes HP/SP, or touches a
  state. `Party.normal_skill?` is `type == 0 || type >= 4`.
- **Items.** A medicine is always field-usable and battle-usable unless
  `occasion_field1` marks it field-only. A switch item reads its own pair,
  `occasion_field2` and `occasion_battle`. A **special** item defers entirely to
  the skill it invokes, on both sides.
- **Special items cast their skill**, with the item standing in for the SP cost:
  the user pays nothing and need not have learnt the skill. `Party#cast_skill`
  grew a `free` flag for exactly that.
- **Switch skills flip their switch**, `Party#cast_switch_skill` returning the
  switch id for the scene to set — the same split `use_switch_item` already used,
  since the switch table lives on the state rather than the party.

## Consequences

The menus fill in:

| | Nepheshel (before → after) | mtf (before → after) |
|---|---|---|
| battle skill menu | 0 → **306** | 0 → **132** |
| field skill menu | 30 → 28 | 2 → **12** |
| battle item menu | 0 → **34** | 0 → **7** |
| field item menu | 41 → **69** | 14 → 14 |

The field skill menu gets slightly *smaller* for Nepheshel, and that is the
change working: a skill that reaches an ally but changes nothing there — a pure
battle stat buff — no longer appears in a menu where it could do nothing.
mtf's field menu grows sixfold because its healing was all filed under category
5. Nepheshel's field item list grows by the 41 switch items it never showed and
loses the 13 thrown bombs that belong in a fight, which are exactly the items its
battle list gains alongside 20 medicines.

Nepheshel's companion summoning becomes reachable by the player: skills 120–125
(ファルを召還 and friends) are switch skills, and casting one now flips the
switch its common event watches. That completes the mechanic whose actor side
ADR 0030 fixed.

Escape (type 1) and teleport (type 2) skills are still not offered — teleport
needs a destination picker this build has no screen for, and between them the two
test beds hold exactly one of each, so there is nothing to measure a real
implementation against. `Party#unsupported_field_skill?` names them so the gap is
declared rather than implied, and the test-bed check excludes them by that
predicate instead of by accident.

The fixtures were part of the problem, so they moved too: `fake_item` now carries
`occasion_field1` / `occasion_field2` under the names the format uses, and four
checks that asserted the old model were rewritten to the real rule rather than
deleted.

Covered by `scripts/rpg2k_logic_check.rb` (subskill categories behave as ordinary
skills; a switch skill casts for its switch and honours its flags; a special item
invokes its skill free of SP; medicine and switch items read their own occasion
fields) and by `scripts/rpg2k_testbed_logic_check.rb`, which now asserts against
the **real** databases that no menu comes back empty, that no skill is castable
from neither menu, and that every special item names a real skill while every
switch item names a switch of its own rather than the default 1. That last set is
the guard this needed: the emptiness was invisible to every fixture.
