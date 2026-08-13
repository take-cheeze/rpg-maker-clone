- **The "frequent miss" enemy option (a hardcoded 90%→70% drop to a
  normal attack's hit chance, never a skill's) is confirmed already
  correct** — no code change needed. `Game::Enemy#attack_hit_rate` already
  reads the schema's `miss` field this way, and `Game::Battle.hit_rate_of`
  feeds it into `Battle#to_hit`'s base term at the basic-attack path's one
  call site; a skill's own hit chance reads the skill row's `hit` field
  directly, with no code path back to an attacker's `attack_hit_rate` at
  all. The claim only lacked its own regression coverage, now added to
  `scripts/rpg2k_logic_check.rb`.
