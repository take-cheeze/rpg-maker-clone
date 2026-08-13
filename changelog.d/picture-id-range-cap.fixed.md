- **Show Picture now no-ops on a picture id outside RPG2000's 1..50 range**,
  instead of tracking the picture anyway. `Game::State#show_picture`
  (`mruby-rpg2k/mrblib/game.rb`) only rejected `id <= 0`; RPG2000's editor
  caps the Show Picture id field at 50 (a fixed-size internal slot array —
  the same fact the already-implemented "50 concurrent picture slots, higher
  id always draws on top" behaviour is built on), so an id above that is not
  a real picture and RPG_RT does nothing with it. Fixed with a new
  `Game::State::MAX_PICTURE_ID = 50` and an upper bound alongside the
  existing `id > 0` check; `#move_picture`/`#erase_picture` need no matching
  guard, since neither can ever find such an id shown in the first place.
  Covered by a new `scripts/rpg2k_logic_check.rb` check (id 51 is silently
  dropped; the boundary id 50 still works), confirmed to fail against the
  pre-fix code before the fix.
