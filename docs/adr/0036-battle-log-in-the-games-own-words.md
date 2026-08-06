# 36. The battle log speaks the game's own language

Date: 2026-08-06

## Status

Accepted

## Context

The battle log invented its English. `Scene::Map#battle_action_line` composed
"Hero hits Slime for 42", "Slime defends", "Hero misses Slime" — strings written
here, in a runtime for games that are not in English and that ship their own
wording for every one of those lines.

RPG2000 keeps those sentences in the 用語 (term) table, as *predicates* rather
than templates: the database stores 「の攻撃！」 and RPG_RT prints the battler's
name in front of it. A field-by-field audit of the two test beds against the
runtime source says how much of it was going unread:

| | term fields filled in | fields the runtime names |
|---|---|---|
| Nepheshel / mtf-meido-action | **126 of 127** | 2 (`gold`, `normal_status`) |

The battle block alone is fourteen sentences both games wrote and neither could
show: 「の攻撃！」, 「は身を守っている」, 「は様子を見ている・・・」,
「のダメージを与えた！」, 「はダメージを受けていない！」, 「は身をかわした！」 and
the rest.

ADR 0032 already made this argument for the *state* sentences and took them from
the database, noting that a defeat should read 「スライムを倒した！」 rather than
an invented English string. This is the same argument for the action itself, and
it is the larger half: every round prints an action line, where only some print a
state line.

## Decision

`Game::States::BattleText` composes the term table's battle sentences, and
`Scene::Map#battle_action_body` builds the log from it.

- **Predicates, not templates.** Every builder is `name + field`. The
  `%S`-placeholder form EasyRPG supports is an RPG2003 / 2k3E feature and is not
  this runtime's job.
- **More than one line.** RPG_RT prints what the battler *did* and then what it
  did *to the target* as separate messages, so `battle_action_body` returns an
  array: 「スライムの攻撃！」 then 「リトは 7 のダメージを受けた！」.
- **The particle is the rule that is not in the database.** The damage line is
  `name + particle + value + " " + predicate`, and RPG_RT picks the particle by
  side — に for one of theirs, は for one of yours — pairing with the two
  predicates `enemy_damaged` / `actor_damaged`. This is the CP932 branch of
  EasyRPG's `GetDamagedMessage`; the Western-encoding branch uses a plain space
  for both, and this build decodes every string as CP932
  (`LCF.cp932_to_utf8`), so there is no second branch to take.
- **All or nothing per entry.** A blank term drops the whole entry back to the
  composed English. A half-translated line — 「スライムの攻撃！」 with no damage
  sentence under it — reads worse than the English one, and an English-release
  table with half the battle block empty is a real shape.

## Consequences

Both test beds now narrate their own fights. Every basic action (attack, Defend,
Observe, Charge, self-destruct, flee, transform), every damage line from either
side, every no-damage line and every miss comes out of the table; all 7 of the
basic action sentences are filled in in both games, as are both damage
predicates and `dodge`.

Two things are deliberately **not** in this change, and both are held back for a
reason rather than forgotten:

- **A skill and an item keep their composed line.** They announce themselves with
  their *own* sentence — the skill row's `using_message1` / `using_message2`
  (351 and 18 skills across the test beds set one) and the `use_item` term — not
  with a term for "attacking". Reading those is a separate change; until then,
  dropping a skill entry to the bare damage line would lose the only thing that
  names what was cast, so skills and items are excluded whole.
- **The critical-hit line.** `actor_critical` / `enemy_critical` (「会心の一撃！！」
  / 「痛恨の一撃！！」) are filled in in both games, but which side keys them is
  genuinely unclear: EasyRPG's `GetCriticalHitMessage` picks `actor_critical`
  when the **target** is an ally, while the words themselves follow the Dragon
  Quest convention where 会心 is *your* blow landing and 痛恨 is one landing on
  you — which is the attacker's side, i.e. the opposite. One of those readings is
  wrong and the test-bed data cannot settle it, since both games fill both fields
  with the same two strings. Getting it backwards would put the wrong sentence on
  every critical, so the line is left as it was rather than guessed at.

Covered by `scripts/rpg2k_logic_check.rb` (each builder's shape, the two damage
predicates and their particles, and that a blank / missing / absent term yields
nil rather than a bare name), by `scripts/rpg2k_scene_check.rb` (the log a real
`Scene::Map` produces for an attack from either side, a miss, a no-damage blow,
each targetless basic action, an autodestruct's two lines, the all-or-nothing
fallback on a blank term, a skill keeping its composed line, and the state
sentences still following the action ones) and by
`scripts/rpg2k_testbed_logic_check.rb`, which composes every basic action
sentence in **both real term tables** after a battler's name and checks that the
two damage sides really are worded differently and take their own particles.
