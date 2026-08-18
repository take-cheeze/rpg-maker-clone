- **RPG2003's automatic battler placement now honours row.** A back-row
  actor's grid-computed sprite X drops its `row_x_offset` to 0 (was always a
  front-row half-width), matching EasyRPG's `Calculate2k3BattlePosition`, and
  the in-battle Row command repositions the sprite in place the instant a
  toggle succeeds, instead of leaving the pre-toggle position on screen.
