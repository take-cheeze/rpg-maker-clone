- **LCF: event/move-route command lists are decoded once and kept, like
  nested tables already were.** `LCF::Array1D#[]` only cached nested
  `Array1D`/`Array2D` values -- a `:event` chunk (an RPG2000 event page's
  own command list) or `:move_commands` chunk (a Move Route's) re-parsed
  and rebuilt one object per command from scratch on every single read,
  same as the container types used to before that caching existed. Unlike
  a one-off Scene::Map entry cost, this one recurs: `Scene::Map#build_event`
  redecodes every active event's command list on every page-flip (a
  switch-gated dialogue is a routine RPG2000 idiom, not a one-time
  transition), and `Scene::Base::EventResolver#map_event_commands`
  redecodes on every Call Event to a map page -- its sibling
  `#common_event_commands` already got equivalent caching in #1360. Now
  cached the same way as `Array1D`/`Array2D`, dropped by the existing
  `#[]=`/`#delete` write paths like any other cached decode. Verified:
  `scripts/rpg2k_scene_check.rb` (929 checks) and
  `scripts/rpg2k_logic_check.rb` (1139 checks) both pass unchanged, plus a
  standalone script confirming identity-cached reads and correct
  cache-drop on write.
