# 38. What a drain takes

Date: 2026-08-06

## Status

Accepted

## Context

The skill row's `absorb_damage` (吸収) makes the caster gain the HP the skill
takes. 13 of Nepheshel's 306 skills and 5 of mtf-meido-action's 134 set it, and
nothing read it — so every drain spell in both games was an ordinary attack
spell, and the two 用語 sentences that report a drain
(`enemy_hp_absorbed` 「奪った！」, `actor_hp_absorbed` 「奪われた！」, both filled
in in both games) had nothing to report.

## Decision

Read the flag, following RPG_RT.

- **Offensive skills only.** Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, which gates it on
  the skill being non-positive, so the flag rides on the attack branch of
  `Party#battle_skill_command` and a healing skill that sets it drains nothing.
- **The clamp comes first, and that is the whole rule.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine, which clamps the effect to the target's current HP
  *before* applying it, so a 200-damage drain on a 30 HP foe **deals 30 and
  returns 30**. A drain is weaker against a nearly-dead target, not merely
  capped in what
  it gives back — reading it the other way round would have the caster heal 30
  off a corpse it hit for 200, which is the natural implementation and the wrong
  one.
- **The caster still stops at full.** The transfer is `min(hp + absorbed,
  max_hp)`.
- **The log says so.** `BattleText.absorbed` composes the drain line, which is
  close to the recovery line and not the same shape in three places: the particle
  before the pool name is の for one of theirs and は for one of yours (the
  recovery line always takes の), the pool is followed by を rather than が, and
  the two sides have their own predicate. 「スライムのＨＰを 20 奪った！」 against
  「リトのＨＰが 20 回復した！」.
- **The drain line is additive**, unlike the damage line: a database with no
  drain wording drops the extra sentence rather than the whole entry, because
  the damage line above it still reads correctly on its own.

## Consequences

Eighteen skills across the two games do what their rows say. Nothing else moves:
a skill without the flag takes the same path it always did, and the flag rides as
`false` on every other command.

Deliberately not in this change: **SP drain**. A reference implementation has
a matching SP-absorb pair and a `spirit_points` term for it, but an RPG2000
skill has one `absorb_damage` flag rather than a pair, and neither test bed
has a skill whose SP effect is negative — so there is nothing to measure an SP
drain against, and which of `affect_hp` / `affect_sp` the single flag governs
would be a guess. The stat drains some reference implementations also support
are RPG2003.

Covered by `scripts/rpg2k_logic_check.rb` (the drain line's three differences
from the recovery line, nil when either the term or the pool name is blank, the
clamp deals *and* returns only what the target had, the caster stopping at full,
and a skill without the flag draining nothing) by
`scripts/rpg2k_scene_check.rb` (the drain line following the damage line for an
enemy and for a party member, and no line at all when nothing was drained) and by
`scripts/rpg2k_testbed_logic_check.rb`, which drives a **real** 吸収 skill from
each game through a target that cannot pay the full amount.
