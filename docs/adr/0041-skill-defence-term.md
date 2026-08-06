# 41. What blunts a spell

Date: 2026-08-06

## Status

Accepted

## Context

An enemy-scope skill's damage was `skill_effect - target.def / 4`. The effect
half was already RPG_RT's (`power + physical_rate * atk / 20 + magical_rate *
spi / 40`); the defence half was invented here.

RPG_RT blunts the skill with the **same two rates that built the effect**
(EasyRPG's `Algo::CalcSkillEffect`):

```
effect -= physical_rate * target.def / 40
effect -= magical_rate * target.spi / 80
```

So a physical skill is blunted by armour and a magical one by the target's
spirit. A flat `def / 4` coincides with that only when the skill is purely
physical at rate 10 — one shape out of many:

| | enemy-scope skills | differ from `def / 4` * | **purely magical** |
|---|---|---|---|
| Nepheshel | 276 | **211** | **141** |
| mtf-meido-action | 116 | **112** | **81** |

\* against a def-40 / spirit-40 target.

The purely magical column is the part that matters most. 222 skills across the
two games have no physical component at all, and every one of them was being
blunted by the target's **armour** — a stat RPG_RT does not let them see. A
fully plated knight was resisting fire spells with his plate.

Alongside it sat `ignore_defense` (防御無視), unread: 13 of Nepheshel's skills
and 7 of mtf's, every armour-piercing spell in both games being blunted like any
other.

## Decision

`Party#skill_defence_term(sk, target)` is the real term, and `ignore_defense`
switches the whole subtraction off, as RPG_RT does — it skips both halves, not
just the physical one.

- **Both rates, each against its own stat.** `physical_rate * def / 40 +
  magical_rate * spi / 80`. The two divisors differ, and that is RPG_RT's, not a
  simplification: spirit is worth half as much per point in defence as it is in
  offence (`/40` there against `/80` here).
- **A missing stat absorbs nothing.** A battle fixture, or an enemy row that
  leaves spirit out, reads 0 rather than raising — the term is a subtraction, so
  absent means "no help" rather than "no answer".
- **No target, no term.** An all-enemy skill is costed against `nil` before its
  per-target effects are built, and takes the full effect there.

## Consequences

Almost every attack skill in both games now does different damage, and for 222
of them the difference is qualitative rather than numeric: armour stops mattering
to a spell.

The floor is **left alone**: `dmg = 1 if dmg < 1`, where RPG_RT floors the effect
at 0 and then lets a 0 land as a "no damage" line. That is a separate divergence
about whether a skill can whiff for nothing, it is visible in the battle log
rather than in the formula, and folding it in here would have hidden this change
inside it.

Covered by `scripts/rpg2k_logic_check.rb` (a physical skill blunted by armour and
scaled by its own rate; a magical one blunted by spirit and **indifferent to
armour**, shown by doubling each stat in turn; a skill with both rates taking
both halves; 防御無視 skipping the whole term; and a statless target absorbing
nothing) and by `scripts/rpg2k_testbed_logic_check.rb`, which computes the term
for **every** enemy-scope skill in both games against a real target, checks each
of the 222 purely magical ones reads the same through no armour and through 999,
and checks every real 防御無視 skill is blunted by nothing at all.
