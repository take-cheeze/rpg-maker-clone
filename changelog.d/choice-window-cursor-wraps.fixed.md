- **RPG2000 choice window cursor wraps around.** `Scene::Map#drive_message` only
  moved `@choice_index` while it stayed inside the choice list, so pressing Up
  on the first choice or Down on the last did nothing — RPG_RT wraps to the
  other end instead. Up/Down now wrap `@choice_index` modulo the shown choice
  count.
