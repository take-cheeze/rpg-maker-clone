- The **Key Input Processing** (11610) event command is now handled. It waits
  for — or, in no-wait mode, samples — one of a chosen set of buttons and writes
  its RPG2000 key code to a variable (Down 1, Left 2, Right 3, Up 4, Decision 5,
  Cancel 6, Shift 7; highest wins when several are held). The RPG_RT parameter
  layout is followed faithfully, including the pre-1.50 form that packs all four
  arrows into a single flag versus the 1.50+ form with an individual flag per
  direction plus Shift. `Game::Interpreter` records the request and suspends on a
  `:key_input` wait; `Scene::Map` samples real input (triggered edges when
  waiting, held state otherwise) — for foreground events and, so the common
  "parallel process polls a key each frame" idiom works, for parallel processes
  too. RPG2003 number / operator keys and Maniac mouse input are not modelled.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
