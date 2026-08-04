- The **Show Inn / Stay at Inn** (10730) event command is now a playable
  subsystem. A priced inn opens a greeting window with Accept / Cancel choices
  (Accept selectable only when the party can afford the price) and a gold
  window; a free inn (price 0) skips the prompt. Staying deducts the price and
  fully heals the party (HP and MP), and either outcome routes into the
  command's optional `[Stay]` / `[No Stay]` handler branches (markers 20730 /
  20731, closed by 20732), laid out and skipped exactly like a Show Choices
  block. `Game::Interpreter` owns the gameplay — affordability, gold, healing
  and branch routing — and suspends on an `:inn` wait; `Scene::Map` renders the
  prompt and resumes it. The inn fade-out/in and the inn jingle are presentation
  still to come (like the screen-fade commands), so staying heals without them
  for now. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
