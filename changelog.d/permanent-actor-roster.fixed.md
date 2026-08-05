- **A party member who leaves and rejoins keeps everything they had.** RPG2000
  actors now live in a permanent `Game::Actors` roster and the party is an
  ordered list of ids into it (RPG_RT's `Game_Actors`, ADR 0030), instead of the
  party owning its members and rebuilding them from the database row on every
  Change Party Member. Nepheshel's whole companion mechanic runs on that command
  — 5205 of them, 2835 adds and 2370 removes — so dismissing and re-summoning a
  companion used to reset her from level 21 / 16682 EXP / nine learned skills to
  level 1 / 0 EXP / one skill and undo any renaming. The roster is saved and
  restored too: both the Marshal save and `Save<N>.lsd` chunk 108 now carry every
  actor the party has ever held (which is what a genuine RPG_RT save holds), and
  loading a real save no longer discards the companions who were away.
- **`\N[n]` in a message names the live actor**, not the database row, so a hero
  the player named through Enter Hero Name is called what they chose — Nepheshel
  renames actor 1 and then refers to `\N[1]` in 34 messages. **`\N[0]`** is the
  party leader; actor ids are 1-based, so it used to expand to nothing and left a
  boss line reading `\n[0]よ…` without its subject.
- **New check: `scripts/rpg2k_testbed_logic_check.rb`**, which drives a real test
  bed's `RPG_RT.ldb` through the real `Game::Interpreter` — the join of
  `lcf_testbed_check.rb` (real data, never run) and `rpg2k_logic_check.rb` (run,
  never real data). It exists because the party-roster bug above passed every
  fixture check while breaking the actual game. Runs in CI beside the other
  RPG2k logic checks; a game with nothing to exercise is skipped, not failed.
