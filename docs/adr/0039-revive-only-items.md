# 39. A revive is not a potion

Date: 2026-08-06

## Status

Accepted

## Context

The item row's `ko_only` (蘇生専用) marks an item that only works on a fallen
target. Nothing read it, and the four items in the test beds that set it are all
revives of the same shape:

| item | cures | restores |
|---|---|---|
| Nepheshel ドラゴンブラッド | 戦闘不能 | 25% of max HP |
| Nepheshel ドラゴンハート | 戦闘不能 | 100% |
| Nepheshel 気付け薬 | 戦闘不能 | 3% |
| mtf-meido-action Stimulant | 戦闘不能 | 25% |

That shape is what makes the field matter. Reading `ko_only` as nothing did not
merely let the *cure* fire pointlessly on a living ally — the cure is a no-op
there anyway, since they do not carry 戦闘不能. It let the **HP restore** fire.
All four are wastable on a standing, wounded ally as a percentage heal, and
Nepheshel's ドラゴンハート is a full heal that way. The field menu offered them
as effective, which is exactly when a player spends one.

## Decision

`ko_only` blocks the whole item, not just its states.

RPG_RT returns from the item algorithm **before both** the HP and the state
effects are computed — ported from a reference implementation, not
independently confirmed against genuine RPG_RT under wine, whose
item-execution path checks `ko_only` against a living target ahead of the
state loop, with the HP block further down still. So the answer is "does
nothing at all", not "cures nothing".

`Party#ko_only_blocked?(it, actor)` is that test, and it gates two places:

- **`item_effective?`** — so the menu greys the item out on a standing member
  and a player cannot spend it by mistake.
- **`use_medicine`** — per target, so an **all-party** revive passes over the
  members who never fell rather than topping them up. That is the case the
  "not even the HP" reading actually decides; with a single target the menu gate
  would have hidden the difference.

## Consequences

Four revive items in the two games stop being percentage heals. Nothing else
moves: an item without the flag takes the same path it always did, and a
`ko_only` item on a fallen member still cures and still heals, exactly as before.

Left alone: **an item that is `ko_only` and not a revive.** Neither test bed has
one, and RPG_RT's rule as written would make such an item inert on everyone who
is standing regardless of what else it does — which is what this implements, but
without data behind it that is a consequence of the rule rather than a
measurement.

Covered by `scripts/rpg2k_logic_check.rb` (a revive is inert on a standing ally
— menu gate, no HP, nothing spent — works fully on a fallen one, leaves an
ordinary medicine untouched, and an all-party revive skips the members still
standing) and by `scripts/rpg2k_testbed_logic_check.rb`, which drives **every**
real 蘇生専用 item in both games at a standing party leader and then at a fallen
one, first asserting that each really does restore HP when it works — the
property that makes "not even the HP" a different answer from "cures nothing".
