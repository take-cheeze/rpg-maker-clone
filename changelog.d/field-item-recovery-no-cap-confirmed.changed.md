- **The field-menu medicine path has no 999 HP/SP recovery cap, unlike the
  battle skill/item path — confirmed rather than an open yado.tk claim.**
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: its own field-menu item-target scene
  applies a medicine through its party/actor use-item path
  and ends in a bare status-window refresh, no popup of any kind, unlike a
  battle round's own floating heal number — and the HP itself is clamped
  only by the actor's own max-HP value, never a fixed digit
  constant. `Game::Party#use_item`/`#use_medicine` already matches this: it
  applies `#item_recovery`'s raw amount straight through `Actor#change_hp`,
  which clamps to `[floor, max_hp]` and nothing tighter, unlike
  `Game::Battle#apply_skill_hit`'s battle-cast recovery branch (capped at
  999 there). Pinned by a new `scripts/rpg2k_logic_check.rb` check on an
  RPG2003 fixture (needed since an RPG2000 actor's own `max_hp` is itself
  capped at 999): a raw 9999 HP heal against a 9999-max-HP target sitting at
  1 HP lands at the full 9999, not 1 + 999 = 1000 the way the battle-cast
  equivalent clamps.
