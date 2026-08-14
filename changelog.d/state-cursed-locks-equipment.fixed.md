- **A state flagged "cursed" (RPG2003) now locks equipment changes for as
  long as it is inflicted, matching real RPG_RT.** The `situation` (state)
  table's `cursed` field (LCF field 38) was already parsed by
  `mruby-lcf/mrblib/schema.rb` but read nowhere in `mruby-rpg2k`, so a status
  built for exactly this purpose left the field equip menu fully usable.
  Verified against EasyRPG Player's actual C++ source: `Game_Actor::
  IsEquipmentFixed(check_states)` is `data.lock_equipment || (check_states &&
  any inflicted state's own cursed flag)`, and its equip-menu caller —
  refusing to even open a slot's item list, rather than opening it and
  rejecting a choice — always passes `check_states: true`. `Game::Actor
  #equipment_fixed?` now also consults a new `#state_cursed?` (scanning the
  actor's currently-inflicted states for the flag) alongside the actor/class
  row's own `equipment_fixed` trait it already read. Distinct from the
  neighbouring `#slot_cursed?` (a property of the *item* worn in a slot): a
  cursed state locks every slot regardless of what is equipped and unlocks
  the instant it lifts, while a cursed *item* keeps locking its own slot even
  after such a state clears. RPG_RT's Change Equipment event command still
  bypasses this either way, so `Game::Party`'s bag-swapping methods stay
  unguarded, unchanged.
