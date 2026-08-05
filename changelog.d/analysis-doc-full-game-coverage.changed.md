- `docs/rpg2000-sample-analysis.md` now leads with **full-game** coverage
  figures instead of the partial ones it was written from. The original pass
  could only tally databases and common events (its own method note explains
  why per-map data was unreliable); a run against Nepheshel whole — 543 maps,
  11 362 map events, 20 925 pages, 505 common events, **184 166 event
  commands** — reports **100 % correctly handled, 0 feature gaps across 0
  distinct opcodes**, and `--troops` resolves every battle-only command its
  3265 troop pages run. The "Recommended priorities" list is marked as
  completed rather than outstanding. Two caveats are stated with the figures:
  coverage is per *opcode*, not per parameter combination, and one game only
  exercises the commands its author reached for — `ChangeMonsterHP` (13110)
  and `TerminateBattle` (13410) never appear in it and stay fixture-tested.
