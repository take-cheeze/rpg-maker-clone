- **A Change Actor Title override now survives Save/Continue through a real
  `.lsd`.** `LCF::Schema::SAVE_PARTY_ACTOR` (chunk 108)'s field 2 was left
  undecoded because it stayed constant in the one sampled real save, so it
  was not provably the title field from that sample alone. It is now
  supported by a reference implementation's format-documentation library
  (its CSV field list), whose `SaveActor` struct documents field `0x02` as
  `title` (`String`) right next to `0x01` `name` — and every other
  already-confirmed field in this table matches that library's hex tag
  decimal-for-decimal (`0x1F`→31 `level`, `0x20`→32
  `exp`, `0x33`→51 `skill_size`, `0x34`→52 `skills`, `0x3D`→61 `equipped`,
  `0x47`→71 `current_hp`, `0x48`→72 `current_sp`, `0x51`→81 `status` count,
  `0x52`→82 `status`), so `0x02`→2 `title` follows the same scheme — ported
  from that reference documentation, not independently confirmed against a
  genuine save under wine; the same library
  also identifies the other two previously-ambiguous constant bytes as
  `hp_mod` (`0x21`→33) and `sp_mod` (`0x22`→34) — unconfirmed stat modifiers,
  not the title. Field 2 (`title`) is now decoded, `Game::State#to_lsd`
  writes every roster actor's current title into it, and
  `Game::State.from_lsd` restores it — an empty string is applied as a
  legitimate cleared title (`do_change_actor_title` explicitly lets an empty
  command string clear the title, unlike Change Actor Name's blank-is-
  unchanged rule), skipping only the reserve-actor placeholder byte. Covered
  by a new `scripts/rpg2k_logic_check.rb` check (a renamed leader and a
  renamed non-leader roster member both come back with their titles from an
  in-memory `to_lsd`/`from_lsd` round-trip, plus a cleared title round-trips
  as an empty string), confirmed to fail against the pre-fix code (the
  leader's title came back as the database default) before the fix.
