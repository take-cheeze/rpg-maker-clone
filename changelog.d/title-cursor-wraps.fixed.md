- **RPG2000 title menu cursor wraps around.** `Scene::Title` only moved the
  cursor while `@selected_index` stayed inside the command list, so pressing Up
  on New Game or Down on Shutdown did nothing — RPG_RT wraps to the other end
  instead. Up/Down now wrap `@selected_index` modulo the fixed 3-command list.
