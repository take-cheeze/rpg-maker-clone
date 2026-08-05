# 30. Actors live in a permanent roster, not in the party list

Date: 2026-08-05

## Status

Accepted

## Context

`Game::Party` owned its members outright. `add_actor` built a fresh
`Game::Actor` from the database row and pushed it; `remove_actor` dropped the
object on the floor:

```ruby
def add_actor(id)
  return if include_actor?(id)
  @actors.push Actor.new(@db, id)      # <- rebuilt from the database, every time
  @revision += 1
end

def remove_actor(id)
  @actors.reject! { |a| a.id == id }   # <- the only reference; the actor is gone
end
```

That is fine for a game whose party never changes. It is wrong for a game whose
party changes constantly, and Nepheshel is exactly that game: its entire
companion mechanic is Change Party Member (10330), which it issues **5205
times** — 2835 adds and 2370 removes. Tallied by actor id:

| actor | adds | removes |
|---|---|---|
| 2 ファル | 630 | 471 |
| 3 ティララ | 630 | 471 |
| 4 ディーヴァ | 630 | 471 |
| 5 ファル (alt) | 312 | 316 |
| 6 ティララ (alt) | 312 | 316 |
| 7 ディーヴァ (alt) | 312 | 316 |
| 1, 15 | 9 | 9 |

Common event 1 (ファル召還, "summon Fal") adds actor 2; common event 2
(ファルを帰す, "send Fal home") removes her. The player summons and dismisses
companions all game long. Every dismissal threw the companion away and every
summon rebuilt her from the database row, so a levelled companion came back as a
level-1 stranger. Driving those two real common events through the interpreter
against the real `RPG_RT.ldb` measures it exactly — level, EXP, name, HP and
skill count before the swap versus after:

```
after levelling: id2 [21, 16682, "RENAMED", 3, 9]
in party after remove: [15]
after rejoin:    id2 [1, 0, "ファル", 30, 1]
```

Level 21 → 1. 16682 EXP → 0. Nine learned skills → one. The rename undone.
Everything the player had invested in that companion, discarded on the round
trip. (The other test bed, mtf-meido-action, issues no Change Party Member at
all, which is why this went unnoticed: it is a Nepheshel-shaped bug.)

The save layer had the same hole from the other end. `#to_h` and `#to_lsd` wrote
one per-actor entry per *current member*, and `.from_lsd` skipped saved actors
who were not in the party:

```ruby
(save[108] || []).each do |aid, sa|
  next unless roster.include?(aid)      # <- a companion who is away is dropped
```

So even the actors that survived in memory did not survive a save.

The `.lsd` format itself says what the model should be. `AGENTS.md` already
records chunk 108 (`SAVE_PARTY_ACTOR`) as "one entry per actor the party has
**ever** held" — a real Nepheshel save carries rows for companions who are not
currently along. A table keyed by actor id, holding everyone the game has met,
is not something to invent: it is what RPG_RT serialises, because RPG_RT keeps
one `Game_Actor` per database row for the whole session (`Game_Actors`) and
treats the party as nothing more than a list of ids into it.

A second, smaller symptom shared the same root. The `\N[n]` message control code
resolved through `@db.player[id].name` — the *database* row — so a hero the
player had named could not be addressed by the name they chose. Nepheshel opens
Enter Hero Name (10740) on actor 1 and then refers to `\N[1]` in 34 messages.
`\N[0]` was worse than stale: actor ids are 1-based, so it resolved to nothing
at all and rendered as the empty string, which is how a boss line reading
`\n[0]よ…` ("…, you") lost its subject.

## Decision

Introduce `Game::Actors`, a permanent roster keyed by database id, and demote
`Game::Party` to an ordered view over it.

- `Actors#[]` builds an actor from the database on first request and caches it
  from then on — RPG_RT's `Game_Actors::GetActor`. A missing row logs and
  returns nil instead of raising, so a game that references an actor the
  database lacks keeps running.
- `Actors#existing` looks up **without** creating. Read paths use it, so merely
  naming an actor in a message does not enrol them in the roster the save
  writes out.
- `Party#add_actor` takes its actor from the roster, so rejoining is literally
  the same object; `Party#remove_actor` only edits the ordered list.
- `Party#to_h` writes the per-actor tables for the whole roster and keeps
  `actor_ids` as the party proper. `#load_state` restores every id the saved
  tables mention, pulling each through the roster, so an actor who was away when
  the game was saved comes back exactly as they left.
- `State#to_lsd` writes chunk 108 from the roster and `.from_lsd` restores every
  entry in it, dropping the `next unless roster.include?` guard. Both directions
  now match what a genuine save holds.
- `\N[n]` resolves the live roster actor, falling back to the database row for
  an actor the game has never instantiated; `\N[0]` is the party leader.

## Consequences

Nepheshel's companion system works. A summoned companion keeps their level, EXP,
learned skills, equipment, statuses, current HP/SP and any renaming across a
dismissal, a re-summon, and a save taken while they are away — the same three
figures as above now read `[21, 16682, "RENAMED", 3, 9]` at every step.

Saves get slightly larger (per-actor rows for everyone met, not just the current
party) and slightly more compatible: a real `.lsd` written by the editor with
out-of-party companions in chunk 108 now loads them instead of discarding them.
Older Marshal saves still load — an absent roster entry simply leaves that actor
at their database defaults, which is what the old saves recorded anyway.

The roster is reachable as `state.party.roster`. Placing it behind the party
rather than on `Game::State` keeps every existing `state.party.*` call site
working and keeps the two halves — who exists, who is fighting — owned by one
object; the trade-off is that "roster" now means two things in the code's
history (the old `.lsd` field name for the party id list is renamed
`member_ids` at the one place both appear, to keep that straight).

Follow-up this does not do: `Change Actor Name` / `Change Actor Title` (10610 /
10620) still only find actors through `Party#actor_by_id`, so they act on
current members only. Neither test bed uses either command, so there is nothing
to measure the correct behaviour against yet.

Covered by `scripts/rpg2k_logic_check.rb` (rejoining keeps state; the roster
builds each id once; the save carries actors who are out of the party) and
`scripts/rpg2k_scene_check.rb` (`\N[n]` names the live actor, `\N[0]` the
leader).

Fixtures were not enough to find this, so the change also adds
`scripts/rpg2k_testbed_logic_check.rb`: a new harness that drives a **real**
test bed's `RPG_RT.ldb` through the **real** `Game::Interpreter`, joining what
`lcf_testbed_check.rb` (real data, not run) and `rpg2k_logic_check.rb` (run, not
real data) each do half of. It finds every actor a game's common events both add
and remove, then runs the game's own commands to take each companion out and
bring them back — across a plain swap, a Marshal save and a `.lsd` round trip.
Nepheshel's three companions give 18 checks; against the old party model they
fail with the state diff spelled out (`level 6 → 1`, `645 EXP → 0`, three skills
→ one). A game with no companion swaps, like mtf-meido-action, is reported and
skipped rather than failed. It runs in CI beside the other RPG2k logic checks.
