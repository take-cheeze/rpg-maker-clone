# 32. A status has to do the thing it is named after

Date: 2026-08-05

## Status

Accepted

## Context

`Game::Battle` modelled four of a state's fields: its action `restriction`, its
per-turn slip damage, its `hold_turn` and its `auto_release_prob`. Everything
else in the 状態 table went unread — and three of the unread fields are the ones
that give the most familiar statuses in the genre their entire meaning.

Tallying what the two test beds actually ask for:

| field | what it does | Nepheshel (of 25) | mtf (of 10) |
|---|---|---|---|
| `reduce_hit_ratio` | spoils the victim's aim | **9** | **2** |
| `release_by_attack` | a blow shakes the state off | **4** | **3** |
| `restrict_magic` | seals magic | **2** | **1** |

Read as behaviour rather than as counts:

- **Blind did not blind.** mtf-meido-action's Blind sets `reduce_hit_ratio` to
  20 — a blinded battler should hit one time in five — and Nepheshel's 盲目 and
  恐怖 halve it, with the four poisons taking 15% off. Nothing read the field, so
  every one of those statuses was cosmetic. Blind in particular had no other
  effect at all: it is `reduce_hit_ratio` and nothing else.
- **Nothing woke a sleeper.** Nepheshel's 睡眠 sets `release_by_attack` to 80 and
  its 混乱 to 30; mtf's Sleep is 50 and its Provoke and Confuse 25. Hitting a
  sleeping battler is *the* way out of sleep in this genre. Without the field,
  sleep lasted until its own timer ran down no matter how hard it was hit.
- **Silence did not silence.** 封印 and 恐怖 in one game, Silence in the other,
  all set `restrict_magic` with a threshold of 1. All three left their victim
  casting freely.

None of this was visible to the existing checks, because the fixtures modelled
the same four fields the runtime did. `FakeStateDef` had seven members and three
of the fields above were not among them, so no fixture could express the
behaviour that was missing.

## Decision

Read the three fields, following RPG_RT:

- **`reduce_hit_ratio`** scales the attacker's to-hit chance. Where a battler
  carries several such states the **lowest** ratio wins rather than the product
  — EasyRPG's `Game_Battler::GetHitChanceModifierFromStates` keeps a running
  `std::min`. A state without the field reads as 100, not 0; the existing
  `state_field` helper defaults to 0, which here would have meant "always miss",
  so this field gets its own reader.
- **`release_by_attack`** rolls per state after a **normal attack** that the
  target survives. Normal attacks only: EasyRPG calls `BattlePhysicalStateHeal`
  from `Normal::vExecute` and from nowhere else, so a skill never shakes a status
  loose. Its `release_by_damage * physical_rate / 100` reduces to the stored
  percentage for a normal attack, which is wholly physical. The ids removed ride
  back on the attack's log entry as `:woke` so the battle log can report them.
- **`restrict_skill` / `restrict_magic`** seal a skill whose `physical_rate` /
  `magical_rate` reaches the state's matching threshold
  (`Game_Actor::IsSkillUsable`). A threshold of 1 — what all three sealing states
  in the test beds use — seals everything with any magic in it and leaves a
  purely physical skill alone. `Game::Battle#skill_sealed?` is public because
  both the battle menu and the enemy AI consult it: a silenced enemy's action
  entry no longer fires, and a silenced actor's sealed skills come off the menu
  rather than being offered and then refused.

## Consequences

The statuses work. Measured against the real state tables, with the base to-hit
at 90%:

| | accuracy, unafflicted | afflicted |
|---|---|---|
| mtf Blind (ratio 20) | 94.6% | **19.6%** |
| Nepheshel 恐怖 (ratio 50) | 94.6% | **44.6%** |

A 25% `release_by_attack` state comes off on 25.0% of blows over 4000 rolls, and
a sealing state seals 183 of Nepheshel's 183 magic skills and 100 of mtf's 100
while touching none of their 123 and 34 purely physical ones.

Nothing else moved. Running **every** troop in both test beds — 157 fights and
88 fights — gives byte-identical results to before the change: the same
victory/defeat split, the same 1847 and 1726 swings, the same 501 and 708 misses.
The new code only fires when a state carries the field, so an unafflicted battler
takes exactly the path it did.

Two related gaps stayed open, and were stated rather than implied. The first is
now closed:

- **Map-step slip damage** (`hp_change_map_steps` / `hp_change_map_val`) — a
  status that drains HP as the party walks. mtf-meido-action's Poison is the only
  state in either bed that uses it (1 HP every 4 steps) and it needs a step
  counter on `Game::State` plus a hook in `Scene::Map` that nothing else wants
  yet, so it was left out rather than half-built. **Implemented since** — the
  counter lives on `Game::State` (`#walk_step`), the drain in
  `Game::Party#apply_map_step_damage`, and the field reading in
  `Game::States.map_step_drain`. Three decisions worth recording, none of them
  visible in the two fields themselves:
  - **It sums, where the battle side picks.** Every effect above resolves
    through the *significant* state, so two ailments give one behaviour. The map
    drain instead adds each afflicted state's due amount, so a doubly-poisoned
    member loses both.
  - **It cannot kill.** The drain goes through `change_hp` with death
    disallowed, flooring at 1 HP. That is RPG_RT's rule, and it is what keeps
    this off the `check_game_over` path the twelve party-damaging event commands
    are on — there is no way for walking to wipe the party.
  - **A teleport is not a step.** A step is counted for the player's own
    movement and for a forced move route, one per landing (so a jump counts
    once). A teleport moves the party without walking it; counting it would let
    an event chain drain a poisoned party by shuffling it between maps.
- **`affect_type` stat halving / doubling** and the RPG2003-only `avoid_attacks`
  and `reflect_magic` — no state in either test bed sets any of them, so there is
  nothing to measure an implementation against.

Covered by `scripts/rpg2k_logic_check.rb` (a blinding state scales accuracy and
the worst of several wins; a blow shakes off a state that allows it and leaves a
0% one, and a killing blow shakes off nothing; a sealing state blocks by
threshold) and by `scripts/rpg2k_testbed_logic_check.rb`, which asserts the same
three against the **real** 状態 tables: every blinding state scales accuracy by
exactly its own ratio, the game's most-releasable state does come off within 200
blows, and every sealing state seals some magic while leaving rate-0 skills
alone.

## Addendum: the sentence for a state that was already there

Date: 2026-08-06

The state row carries a fifth sentence beside the four above: `message_already`,
for something trying to inflict a state the target is **already** carrying —
「はすでに毒に冒されている！」. It was parsed and unread, and the runtime went
silent in exactly that case: `roll_inflict` skipped a state the target had and
reported nothing.

Silence is the wrong answer, and not for a cosmetic reason. RPG_RT counts an
already-carried state as a **success**, and it decides that *before* rolling the
skill's accuracy — EasyRPG's `AddAffectedState(StateEffect::AlreadyInflicted)`
`continue`s ahead of the `PercentChance`. So a Poison Sting on an already
poisoned foe always announces itself, where a roll would have gone quiet some of
the time, and a 0%-accuracy skill announces it too. Making the report depend on
the roll would have been the natural guess and it is wrong.

`roll_inflict` now returns `[inflicted, already]`, the battle entry carries
`already:`, and `Scene::Map#battle_state_lines` prints
`Game::States.already_message` for each — one wording for both sides, like the
recovery line rather than the split actor/enemy inflict pair. The scene keeps its
composed fallback for a database that leaves the sentence blank.

15 of Nepheshel's 25 states and 7 of mtf-meido-action's 10 fill the field in,
against 99 and 40 skills that name at least one state — so this is text the games
wrote and expected to see.

**`message_affected` is deliberately still unread.** 15 and 4 states fill it in,
and the wordings (「は眠っている・・・」, 「は麻痺していて動けない！」,
「は毒で80のダメージを受けた!」) read like the line for a turn a state costs the
battler. But EasyRPG defines `GetStateAffectedMessage` and never calls it from
either battle scene, so there is nothing to pin *when* RPG_RT prints it. Guessing
would put invented text in the battle log, which is the thing this ADR set out to
stop.

Covered by `scripts/rpg2k_logic_check.rb` (an already-carried state reports
rather than lands, does so at 0% accuracy, does so for an immune target, does not
stack, and a clear target reports nothing), by `scripts/rpg2k_scene_check.rb`
(the sentence reaches the action banner for an ally and an enemy target alike,
and a state with no sentence still gets announced) and by
`scripts/rpg2k_testbed_logic_check.rb`, which composes every real
`message_already` in both games after two different battler names and drives a
real state through a 0%-accuracy skill.
