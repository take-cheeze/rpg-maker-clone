- **Inflicting the Knockout state (id 1) via a skill's state-effect list now
  ignores the target's A-E resistance rank entirely**, matching yado.tk:
  RPG2000 has no separate instant-death mechanic, so an "instant death"
  spell is just a skill whose state-effect list names Knockout directly, and
  the site documents its landing chance as governed solely by the skill's
  own occurrence-rate operand, never scaled down by `state_ranks` the way
  every other status is. `Game::Battle#state_susceptibility`
  (`mruby-rpg2k/mrblib/game.rb`) now returns 100 unscaled whenever the
  target state id is `Game::Actor::DEATH_STATE`, before consulting
  `state_ranks` at all.
