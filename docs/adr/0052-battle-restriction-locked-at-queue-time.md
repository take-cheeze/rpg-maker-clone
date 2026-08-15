# 52. A do-nothing restriction is locked in when a battler's turn is queued, not re-checked live when it runs

Date: 2026-08-15

## Status

Accepted

## Context

`Game::Battle#step`/`#step_action` call `#apply_turn_states(b)` on a battler
the instant it is dequeued and about to act. That method rolls the battler's
states for auto-recovery, applies slip HP/SP, and returns whether the battler
may act at all this turn (`false` for a still-active "do nothing" restriction
-- asleep/paralysed). Because it reads `b.states` live, at dequeue time, a
battler who was asleep when this round's turn order was built but gets cured
by *something else* before its own turn comes up -- an ally's Esna/Cure this
same round, or any other mid-round state removal -- was allowed to act.

Found via community デフォ戦bot trivia: "once afflicted with a 'cannot act'
status, even if it's cured before your turn comes up, you still can't act
that turn; the same goes for Silence blocking magic." Checked against
EasyRPG's real source rather than trusted from the trivia alone, the same
discipline PR #861 (mid-battle party roster sync) and PR #883 (self-destruct/
hidden) applied earlier this session:

- `Scene_Battle_Rpg2k::SelectNextActor`/`CreateEnemyActions`
  (`src/scene_battle_rpg2k.cpp`) decide each battler's action for the round.
  For an actor: `if (!active_actor->CanAct()) { SetBattleAlgorithm(None);
  battle_actions.push_back(active_actor); ... }` -- a restricted battler is
  queued with a `None` algorithm right there, at selection time, before the
  round's `battle_actions` queue is even sorted by `CreateExecutionOrder`.
- `Game_Battler::AddState` (`src/game_battler.cpp`) fires whenever a state
  lands on a battler mid-round, live: if the battler's `GetSignificantRestriction()`
  is no longer `Restriction_normal` (or, for a queued Skill, the skill itself
  becomes unusable -- Silence), it overrides that battler's *already-queued*
  algorithm to `None`, again right there, live -- this is what stops a
  battler who was fine at selection time but gets put to sleep by an earlier
  action this same round.
- `Scene_Battle::PrepareBattleAction` (`src/scene_battle.cpp`) runs again
  immediately before each queued action actually executes (`ePreAction`,
  right before `eBattleAction`): `if (!battler->CanAct()) { if (...GetType()
  != None) SetBattleAlgorithm(None); return; }`. This can only ever *tighten*
  the lock (force `None` if not already); it has no branch that turns an
  already-`None` algorithm back into a real one.
- `ProcessBattleActionBegin` (`src/scene_battle_rpg2k.cpp`), the very start of
  running a queued action, calls `BattleStateHeal()`/`ApplyConditions()` --
  this codebase's own `#apply_turn_states` -- unconditionally, live, at this
  exact moment (the same relative timing this codebase already used). But its
  result (a state healing right here, or not) never feeds back into which
  algorithm runs: `ProcessBattleActionUsage`'s own gate is `if
  (action->GetType() == None) { finish without acting; }`, checked against
  whatever `PrepareBattleAction` already decided, upstream of this call.

So real RPG_RT's "can this battler act" decision is a **one-way lock**, not a
live read: a battler is barred from acting the moment a do-nothing (or, for a
queued Skill, silence) restriction is true -- at selection/queue time, or the
instant one lands mid-round via `AddState` -- and nothing in the reference
ever reverses that lock for the rest of the round, no matter what cures the
underlying state afterward, including the battler's own turn-start heal roll
running in that same call. This codebase's live re-check at dequeue got the
"newly restricted mid-round" half of that right (by accident of always
re-reading current `states`) but missed the "cured before the queued turn
runs" half entirely.

## Decision

- `Combatant` gains one field, `queued_no_act` (nil/false = "not locked",
  matching every existing fixture that never goes through `#refill_queue` at
  all -- direct `Game::Battle.new` construction followed by `#run`/`#run_round`
  without `#begin_round` still calls `#refill_queue` via `#step`, so this is
  covered, but a bare `#apply_turn_states(b)` call in isolation, as a few
  older checks still do, is unaffected).
- `#refill_queue` snapshots it once the round's queue is built: `@queue.each
  { |b| b.queued_no_act = do_nothing_restricted?(b) }`, mirroring
  `SelectNextActor`/`CreateEnemyActions`'s `!CanAct()` check at the same
  relative point (nothing acts between queue-build and this snapshot, so
  checking here is equivalent to checking at selection time).
- `#step` and `#step_action` still call `#apply_turn_states(b)` unconditionally
  at dequeue -- slip damage, regen and the auto-recovery roll are real,
  visible effects that must still happen even for a battler who cannot act --
  but now additionally force `can_act = false if b.queued_no_act`, so a lock
  set at queue time (or picked up live by the unchanged `#apply_turn_states`
  read, for the "newly restricted mid-round" case `AddState` covers) always
  wins over anything that clears the state in between.

Deliberately not attempted: the full bidirectional ratchet EasyRPG's
`AddState`/`RemoveStates` implement, where a state landing on a battler
*after* the round's queue was built also permanently locks that battler out
even if it is cured again before their own turn -- e.g. afflicted by an
earlier ally's stray effect, then cured by a second effect, all before this
battler's own queued turn, in the same round. That would need hooking every
site in this codebase that inflicts a state on a battler mid-battle (skill
effects, weapon-on-attack states, counter effects, ...) to also set
`queued_no_act`, which is a much larger, invasive change touching call sites
across the skill/attack system rather than the two queue/dequeue points this
fix touches. The `#apply_turn_states` live read at dequeue still catches the
much more common case -- restricted mid-round and *still* restricted at
dequeue -- unchanged; only the narrower double-flip inside one round is out
of scope here, and does not match the trivia's own claim, which is about a
single cure before the queued turn, not a cure-after-a-second-affliction.

The Silence half of the trivia ("cured before your turn, still can't use
magic") is the same lock mechanism from RPG_RT's side (a Skill queued before
Silence lands has its algorithm forced to `None`/skipped by `AddState`'s
`IsSkillUsable` recheck, same as the do-nothing case), but this codebase does
not yet consult `#skill_sealed?` when a skill command is being selected at
all (a battler can freely queue and cast a sealed skill today -- see
`#skill_sealed?`'s own comment: "nothing consulted either field"). That gap
is unrelated to timing and pre-dates this fix; it is not touched here.

## Consequences

A battler asleep/paralysed when this round's queue was built loses that
turn even if the state clears by some other means before its own turn comes
up -- matching real RPG_RT, not the live-recheck this codebase had before. A
battler who becomes newly restricted mid-round, before their own queued turn,
still correctly loses that turn too (unchanged, still covered by the live
`#apply_turn_states` read `queued_no_act` is OR'd against, not replaced by).
Every other `#apply_turn_states` call site -- direct calls in older checks
that never go through `#refill_queue` -- is unaffected, since `queued_no_act`
defaults to falsy.

Covered by two new checks in `scripts/rpg2k_logic_check.rb`, each written to
fail under the *other* implementation as well as the pre-fix one: a do-nothing
restriction present when the queue is built still blocks the turn even after
the state is cleared before dequeue (fails under a purely-live recheck); a
do-nothing restriction that lands only after the queue is built still blocks
the turn live (fails under a purely queue-time-locked implementation with no
live recheck at all).
