# 33. What you are wearing changes how you fight

Date: 2026-08-05

## Status

Accepted

## Context

`Game::Actor` already surfaced some of what equipment does in a fight — the
weapon's base `hit`, its elemental `attribute_set`, and whether any piece of gear
carries `prevent_critical`. The rest of RPG2000's equipment combat flags were
parsed by the schema and read by nothing.

Auditing the database fields the test beds set against the fields the runtime
mentions anywhere turned up a cluster of them:

| field | what it means | Nepheshel | mtf |
|---|---|---|---|
| `dual_attack` (二刀流) | the weapon swings twice | **13** weapons | 0 |
| `ignore_evasion` (必中) | the attack cannot be evaded | **13** weapons | 0 |
| `half_sp_cost` (MP消費半分) | skills cost half | **6** items | 1 |
| `strong_defence` (強力防御) | Defend halves damage again | **7** actors | 0 |

Read as behaviour: thirteen of Nepheshel's weapons advertise a second swing and
delivered one; thirteen more promise never to miss and missed; six accessories
promise cheaper magic and charged full price; and seven of its fifty actors —
including リト, the hero — have a guard that should be twice as good as everyone
else's and wasn't.

None of it was reachable by the existing checks. `fake_item` had no member for
any of the three item flags and `FakePlayerRow` had none for the actor one, so
no fixture could express the difference between a 二刀流 blade and a plain one.

## Decision

Read the four fields, following RPG_RT:

- **`dual_attack`** makes a basic attack land twice
  (EasyRPG's `GetNumberOfAttacks`: `weapon.dual_attack ? 2 : 1`). A new
  `Battle#swing` wraps `deal_attack` and returns an array for the second blow,
  so the log reads exactly like the enemy's own dual-attack action — including
  that rule's "the second swing only lands if the first did not fell the
  target", which `swing` reuses rather than reinvents.
- **`ignore_evasion`** drops the agility term from the to-hit calculation:
  RPG_RT's `CalcNormalAttackToHit` returns before applying evasion for such a
  weapon, leaving the weapon's own hit rate. The attacker's **own** statuses
  still apply on top — what the flag ignores is the *target's* evasion, not a
  blindness spoiling the wielder's aim (ADR 0032), and the two compose.
- **`half_sp_cost`** halves a skill's cost, **rounding up**, so a 1-SP skill
  still costs 1 (EasyRPG's `cost = (cost + 1) / 2`). Any slot grants it, not
  just the weapon — Nepheshel's 賢者の指輪 is an accessory. `Party#skill_cost`
  asks whatever it was handed, which is a `Game::Actor` in the menus and a battle
  snapshot in a fight, so both paths get it from one place.
- **`strong_defence`** halves damage a second time while defending — a quarter
  rather than a half (`AdjustDamageForDefend` applies a second `dmg /= 2`). It is
  a property of the actor row rather than of gear, and an RPG2003 class overrides
  it the way it already overrides the growth curves.

The three item flags are read through one `Actor#equipment_flag?` helper, since
"any equipped piece carries this boolean" is the shape all of them share.
`Combatant` grew four members (`strikes`, `ignores_evasion`, `strong_defence`,
`half_sp_cost`) carried across by `from_actor`.

## Consequences

The gear does what it says, measured against the real tables:

| | without | with |
|---|---|---|
| swings per attack (サクリファイス) | 1 | **2** |
| to-hit vs an agi-999 foe (ダガー) | 82% | **98%** |
| a 7-SP skill (賢者の指輪) | 7 SP | **4 SP** |
| damage while defending (リト) | 41 | **20** |

The last is one actor with only the flag toggled, so nothing but the flag
accounts for it.

Nothing else moved. Running every troop in both test beds — 157 fights and 88 —
gives byte-identical results to before: the same outcomes, the same 1847 and 1726
swings, the same 501 and 708 misses. Neither test bed's *starting* party wears
any of the flagged gear, so the sweep exercises the unchanged path and confirms
it is unchanged.

Left for a follow-up, and deliberately not guessed at here:

- **A weapon's `critical_hit` bonus** — 75 of Nepheshel's items carry one, the
  largest count in the audit. It is the one flag that cannot simply be read,
  because RPG_RT computes a *probability* (`1/critical_hit_chance` from the actor
  plus the best weapon's `critical_hit` as a percentage) while this build models
  criticals as a 1-in-N denominator. Folding the bonus in means moving that
  representation to a probability, which touches every crit fixture and deserves
  its own diff and its own before/after.
- **`attack_all`** (7 weapons) — a normal attack that hits every enemy. Its
  handling is not in `algo.cpp` with the others, and rather than guess at how the
  damage and log entries should read it is left declared.
- **`preemptive`** (17 items) and **`raise_evasion`** (13) — the first wants the
  battle's `first_strike` wired to gear; the second has nowhere to land until
  the to-hit formula grows a separate evasion term, since RPG2000's is expressed
  purely in agility.

Covered by `scripts/rpg2k_logic_check.rb` (a 二刀流 weapon swings twice and skips
the second swing on a felled target; a 必中 weapon drops the evasion term but
still suffers its wielder's blindness; 強力防御 halves what an ordinary guard
leaves; MP消費半分 halves a cost rounding up, and a percentage cost too) and by
`scripts/rpg2k_testbed_logic_check.rb`, which asserts against the **real** item
and actor tables that every 二刀流 weapon in the game grants two strikes, every
必中 weapon hits at its own rate against an unhittable target, and every
MP消費半分 item halves a real skill's cost from the slot its own type names.
