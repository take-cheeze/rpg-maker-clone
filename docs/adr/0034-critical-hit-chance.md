# 34. Critical-hit chance is a probability, not a denominator

Date: 2026-08-05

## Status

Accepted

## Context

ADR 0033 read four equipment combat flags and deliberately left a fifth: a
weapon's `critical_hit` bonus, the largest count in that audit at **75 of
Nepheshel's items**. It was left because it is the one flag that cannot simply be
read.

RPG2000 stores a critical chance in two incompatible shapes. The actor row
carries a **denominator** — `critical_rate` 20 means one blow in twenty — while a
weapon carries a flat **percentage** on top. RPG_RT adds them:

```cpp
float crit_chance = dbActor->critical_hit ? 1.0f / dbActor->critical_hit_chance : 0.0f;
float bonus = 0;
ForEachEquipment<true, false>(GetWholeEquipment(),
    [&](auto& item) { bonus = std::max(bonus, (float)item.critical_hit); }, weapon);
return crit_chance + (bonus / 100.0f);
```

This build modelled only the denominator — `Combatant#crit_denom`, rolled as
`rng.random(denom) == 0` — and a denominator has nowhere to put "+10%". So every
one of those 75 bonuses did nothing.

Two details of that snippet are worth stating, because both are easy to get
wrong and the second nearly went wrong here:

- The equipment bonus is the **best** weapon's, not the sum — `std::max`.
- `ForEachEquipment<true, false>` is `<allow_weapon, allow_armor>`, so the field
  is read **from weapons only**. That matters enormously in this data: of the
  seventy-five items Nepheshel sets it on, the six carrying **+100%** are all
  armour or accessories (龍の鱗, 光の衣, 翼 …). Reading them would have handed
  out gear that criticals on every blow. The weapons that legitimately carry the
  field run +2% to +60%. The field is simply inert outside the weapon slot,
  exactly as its sibling `hit` already was.

## Decision

Carry the chance in **basis points** (1/10000) rather than as a denominator, and
sum the two sources on that common scale: `10000 / critical_rate` from the row,
plus the best equipped weapon's percentage times 100. `Combatant#crit_denom`
becomes `crit_chance`, `Game::Enemy` computes the same way (enemies wear nothing,
so there is no bonus to add), and `Battle#critical?` rolls under it.

Basis points rather than percent because the base is often a fraction of one:
1/30 is 333 bp, and rounding it to 3% would be a 10% error in the rate.

### The roll needed its own draw

`Rng#random(n)` is `next_int % n`, and the generator's period is **prime**
(65537). A modulus of a prime period never divides evenly: the low
`PERIOD % n` values come up once more often than the rest. At the scales the
codebase already used — `random(30)`, `random(100)` — the surplus is a handful of
draws out of thousands and is invisible.

At scale 10000 it is not. The surplus is 5537 values, all bunched at the bottom
of the range, which is precisely where a "roll under a small threshold" test
looks. Measured over 200k draws, `random(10000) < 333` fires **3.562%** of the
time where 1/30 is 3.333% — the representation change would have quietly handed
every battler in both games a ~7% relative crit boost on top of the feature.

So the crit roll uses a new `Rng#scaled(scale)` — `next_int * scale / PERIOD`
— which is monotonic and therefore spreads the same unavoidable unevenness
across the range instead of piling it under the threshold. Over the same 200k
draws it puts 1/30 at 3.335% and 1/3 at 33.338%. `#random` is left alone: every
existing caller uses a small `n` where it is fine, and changing it would reshuffle
every seeded result in the project for no benefit.

## Consequences

The bonus reaches the roll. Against Nepheshel's real tables, with リト's
`critical_rate` of 1/20:

| | chance | rolled over 3000 swings |
|---|---|---|
| unarmed | 500 bp (5.00%) | — |
| +2% オリハルコンナイフ | 700 bp (7.00%) | 7.4% |
| +10% ファルシオン | 1500 bp (15.00%) | 15.9% |
| +60% 滅びの剣 | 6500 bp (65.00%) | 68.0% |

Wearing 龍の鱗 and 翼 — two +100% **armour** pieces — leaves the chance at the
500 bp base, which is the point of the weapons-only rule.

**Unlike ADR 0032 and 0033, this one moves the needle on seeded fights**, and it
should. Running every troop in both test beds:

| | Nepheshel | mtf-meido-action |
|---|---|---|
| criticals | 29 → **141** | 24 → 18 |
| swings | 1847 → 1607 | 1726 → 1745 |
| victories / defeats | 119/38 → **124/33** | 54/34 → 54/34 (unchanged) |

Nepheshel's starting party carries a weapon whose bonus now counts, so it crits
nearly five times as often, fights end sooner (240 fewer swings) and it wins five
more of its 157 fights. mtf sets no weapon bonus at all, so its outcomes are
identical and its small movement is the RNG stream reshuffling — the base rate
itself is preserved, which the distribution check pins directly rather than
inferring from a battle.

Follow-ups from the ADR 0033 list that remain open: `attack_all` (7 weapons,
whose handling is not in EasyRPG's `algo.cpp` with the others), `preemptive`
(17 items) and `raise_evasion` (13, which has nowhere to land until the to-hit
formula grows an evasion term separate from agility).

Covered by `scripts/rpg2k_logic_check.rb`: the chance sums the row's 1-in-N with
the best weapon bonus, takes the best rather than the sum across weapons, ignores
the +100% armour, and still counts the weapon when the row never criticals on its
own; plus a distribution check that pins `Rng#scaled` within 3% of the true rate
at three thresholds and asserts the modulus overshoots at each.
