- **Battle-page Show Message/Show Choices and the victory/defeat result panel
  now show the blinking keypress arrow** while they wait for a Decision/
  Cancel press, the same `Window#pause` indicator the map's own message box
  already shows. Both are genuine player-input waits — identical in shape to
  the map's `drive_text_message` — but neither `Scene::Battle
  #drive_battle_event_message` nor `#open_battle_result` ever set `.pause`
  on the `Window` they built, even though the native arrow primitive
  (`mruby-rgss/src/lib.cxx`) was already fully implemented and already
  correct on the map.
