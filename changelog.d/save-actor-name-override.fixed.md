- **A non-leader party member's Change Actor Name override now survives
  Save/Continue through a real `.lsd`**, not just through the portable
  Marshal save. `LCF::Schema::SAVE_PARTY_ACTOR` (chunk 108, the whole roster
  the party has ever held) never modelled field 1 — identified in ADR 0014 as
  the actor's renamable name (a decoded real save's field 1 matched its own
  SAVE_TITLE `hero_name` exactly for the leader) but left unmodelled, since
  `Game::State#to_lsd` only ever wrote a renamed *leader's* name, through the
  file-screen title chunk (100, which carries only one name). A companion's
  own Change Actor Name had nowhere to land in the export at all. Field 1 is
  now decoded (`actor_name`), `#to_lsd` writes every roster actor's current
  name into it (not just the leader's), and `Game::State.from_lsd` restores
  it for every actor the chunk covers, leader included — the leader's chunk
  100 restore stays as a second, redundant source (applied last, so it still
  wins for a foreign save that only sets one of the two). Fields 2/33/34
  remain unconfirmed, so a Change Actor *Title* override still does not
  round-trip. Covered by a new `scripts/rpg2k_logic_check.rb` check (a
  renamed leader and a renamed non-leader roster member both come back
  correctly named from an in-memory `to_lsd`/`from_lsd` round-trip, with no
  bytes serialised in between — the check also newly loads the pure-Ruby
  `mruby-lcf/mrblib` sources, stubbing `LCF.cp932_to_utf8`/`utf8_to_cp932`
  the same way `scripts/rpg2k_save_load_check.rb` already does), confirmed to
  fail against the pre-fix code (the non-leader's name came back as its
  un-renamed database default) before the fix.
