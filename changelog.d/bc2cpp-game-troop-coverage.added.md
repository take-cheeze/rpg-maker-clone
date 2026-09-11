- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 1 of
  `Game::Troop`'s own 7 real bytecode methods (the enemy-party container
  for a battle, built from a database Troop row): `#member` (a plain
  4-argument `Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible)` call).
  Added to `mruby-rpg2k-compiled`, needing zero new opcode work and
  finding zero live `bc2cpp.rb` bugs. `#initialize` (one optional
  argument) has the established non-mandatory-arity gap; `#total_exp`/
  `#total_gold`/`#drops` each end in a genuine Ruby block (`#reduce`/
  `#each_with_object`); `#live_members` (`@members.reject(&:hidden)`) was
  checked specifically for whether the `&:symbol` block-pass shorthand
  might be a narrower, already-supported shape -- it isn't: it compiles
  to the same unmodeled `SENDB` opcode a real block literal does, just
  without a preceding `BLOCK` opcode (no closure to create for a
  Symbol-to-proc pass). `#apply_appear_randomly` ends in two more real
  blocks. `#member` is `private`, registered with
  `mrb_define_private_method`.
