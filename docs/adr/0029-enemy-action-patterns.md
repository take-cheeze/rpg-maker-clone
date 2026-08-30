# 29. Enemy action patterns run through an injected AI collaborator

Date: 2026-08-05

## Status

Accepted

## Context

RPG2000 enemies are scripted. Each database enemy row carries a 行動パターン
(action pattern, chunk 42): a list of entries, each with a condition, a `rating`
priority, and a kind — a basic action (attack, dual attack, defend, observe,
charge, self-destruct, escape, do nothing), a skill, or a transformation into
another enemy. RPG_RT walks that table every turn and picks one entry.

The schema had parsed this table for a long time, but nothing read it. Every
enemy in every fight performed a plain basic attack. Tallying the two test beds
showed how much that hid:

| | enemies | actions | skills | basic |
|---|---|---|---|---|
| Nepheshel 2.06 | 300 | 656 | 357 | 299 |
| mtf-meido-action | 115 | 303 | 153 | 150 |

**510 of 959 actions — over half — are skills**, none of which could fire. That
also left a standing gap noted in `docs/TODO.md`: states could be inflicted by
the party's attack skills but never by an enemy, because the only thing an enemy
ever did was swing.

The obstacle was structural rather than algorithmic. `Game::Battle` is
deliberately database-free: it runs on `Combatant` snapshots so a fight can be
seeded and replayed deterministically by the check harnesses, and so the battle
logic has no dependency on the LCF loaders. But an enemy's action pattern needs
things only the outside world has — the skill table to cast from, the enemy
table to transform into, the game switches for the switch condition and its
post-run switch flips, and the party's average level. Reaching for `@db` inside
`Game::Battle` would have dissolved that boundary and made every existing battle
fixture depend on a database.

## Decision

Decode the table into plain data at the edge, and inject the rest as a
collaborator.

- **`Game::EnemyAction`** decodes one row of the table off the LCF row into
  plain fields, with liblcf's `RPG::EnemyAction` constants for the kinds,
  basic actions and condition types. `Game::Enemy` decodes its whole pattern at
  construction (it already captures its other fields there, since the row is not
  kept), and `Battle::Combatant` carries the list into the fight.

- **`Game::EnemyAi`** is a small collaborator holding the database and game
  state, exposing exactly what an action pattern needs: `skill(id)`,
  `enemy(id)`, `skill_command(sk, caster, target)`, `switch?` / `set_switch`
  and `party_level`. `Game::Battle` takes one as an optional last argument.

- Selection is ported from a reference implementation's rating-based algorithm,
  not independently confirmed against genuine RPG_RT under wine: keep the
  entries whose condition holds, find the highest rating, adjust every survivor
  to `rating - max + 10` floored at 0 (so anything more than 10 below the best
  drops out), and pick weighted by the adjusted rating.

- A skill action is cast through `Game::Party#battle_skill_command` — the very
  method the party casts with — so an enemy's spell is costed, elementally
  scaled, accuracy-rolled and inflicts its states by the same code the heroes
  use, rather than by a parallel enemy-only implementation.

Without an `EnemyAi`, an enemy runs whatever basic actions its pattern lists and
degrades a skill or transformation it cannot resolve to a plain attack.

## Consequences

Enemies now fight the way their author scripted them: they cast, heal each
other, transform, guard, charge, blow themselves up and run. Enemy-cast status
infliction falls out for free rather than needing its own path, closing that
TODO gap.

Because the collaborator is optional and absent by default, every existing
seeded fixture produces exactly the results it did before — the 428 pre-existing
logic checks were unchanged by this work — while the live game gets the full
behaviour. The same seam makes the new behaviour cheap to test: the checks
inject a stub `EnemyAi` with a hand-built skill table, with no LCF data
involved.

The trade-off is one more constructor argument on `Game::Battle`, which now
takes ten positional parameters and is at the point where an options hash would
read better. That refactor is deliberately left out of this change so the
diff stays about the AI; it should happen the next time that signature is
touched.

A transformed monster keeps its original battler sprite: the battle screen builds
each sprite once from the troop member's `battler_name`, so swapping it mid-fight
is a scene-side change this did not take on. The fight itself is correct — the
combatant has the new stats, ranks and pattern.

Two limits are known and deliberate. The turn condition is evaluated against the
same battle-turn clock the troop's battle-event pages use, which counts the
first round as turn 1 where RPG_RT's own counter is 0-based — being consistent
with the existing pages matters more than matching the absolute number, and a
game with a "from turn N, every M" enemy action would pin it down. And the
per-battler dual attack hits one target twice; RPG2003's combo multipliers on
top of it are not modelled, as that runtime's ATB layer does not exist here.
