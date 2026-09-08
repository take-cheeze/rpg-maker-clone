- **WOLF RPG Editor (ウディタ/Woditor) map event pages with a repeating
  "カスタム" (Custom) move route now actually loop it** instead of running
  it once and stopping — `Wolf::Interpreter#update_event_movement`
  re-triggers the whole route from its start every `move_frequency`-paced
  interval, forever, the same cadence Random/TowardHero movement already
  uses. All 3 real repeating-route pages in the bundled sample game exercise
  this now. See `docs/adr/0097-wolf-rpg-editor-repeating-custom-route.md`.
