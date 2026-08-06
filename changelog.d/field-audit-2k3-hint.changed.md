- **The field audit tells you which rows are probably RPG2003.** `maker_version`
  is written only by RPG2003 (RPG2000 omits the chunk), so a run covering one of
  each can mark a field that an RPG2003 game sets and no RPG2000 one does —
  16 of the 120 currently unread. That is the single most common reason a
  high-ranked row turns out not to be work: `terrain.footstep` and the
  `situation.hp_change_type` / `sp_change_type` pair have joined the `NOT_OURS`
  table for exactly that reason. The mark is a filter, not a proof, in either
  direction, and the script says so: an RPG2000 editor still writes fields
  RPG_RT ignores, so `levitate` and `state_chance` are set by Nepheshel and are
  2k3-only anyway, while a marked field can still be a real RPG2000 feature the
  2000 test bed never used. Each game is now labelled `(2k)` / `(2k3)` in the
  header, and the hint is suppressed when a run covers only one maker.
