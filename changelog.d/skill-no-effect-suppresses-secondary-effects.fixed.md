- **An attack skill that lands but changes neither HP nor MP (an MP-only
  skill against an already-0-MP target, for example) now suppresses its
  whole hit** — no inflicted/cured states, no stat mods — the same way a
  missed hit already does, instead of still rolling and applying those
  secondary effects. Confirmed by an actual wine A/B against genuine
  RPG_RT.exe: a real skill bundling an MP-only effect with a state
  effect, cast against a target already at 0 MP, only ever logged the
  skill's own failure sentence ("has no effect"), never a state-landed
  message. `Game::Battle#apply_skill_hit` (`mruby-rpg2k/mrblib/game.rb`)
  now computes a `no_effect` flag and `Scene::Battle#skill_achieved_nothing?`
  reads it alongside `missed`.
