- **Fixed a crash on Wio Terminal builds when curing a status condition
  outside battle, or opening the field Skill menu on a state-only skill.**
  `Game::Actor#state_persists_type?` and `Game::Party#field_skill?` both
  read `Battle::STATE_PERSISTS_ON_MAP`, a constant on `Game::Battle` --
  which wio's build already excludes (ADR 0107) -- raising
  `NameError: uninitialized constant Game::Battle` on an ordinary,
  non-battle code path. The constant now lives on `Game::States`, which
  every target compiles; `Game::Battle`'s own copy aliases it. See ADR 124.
