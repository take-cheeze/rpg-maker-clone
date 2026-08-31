- **Field menu:** the party-status panel now draws each member's own face
  graphic (48x48, cropped from their FaceSet the same way the message
  window's portrait already is), and the condition text moved from the
  name row onto the Lv row ("LV 2  Normal") — both confirmed against a
  genuine RPG_RT.exe screenshot (Nepheshel), whose own panel draws a
  portrait and reads Lv/condition together on one line, neither of which
  this build did before. EXP now shares the name row, right-aligned,
  instead of a line of its own — the portrait's 48px height is exactly
  three 16px text lines, so a fourth line would either overflow it or force
  every row taller than it needs to be.
- **Field menu:** every window on this screen (command list, party-status
  panel, gold, the End Game confirm prompt) now actually blinks its
  selection cursor — `Scene::Menu#update` never called `Window#update` on
  any of them at all, so `@cursor_frame` never advanced and the highlight
  sat frozen on its first frame. `Scene::Title`'s own screen already does
  this for its one window; this screen just never picked up the same call.
- **Fixed:** `RPG2k::Window` now hides its selection-cursor highlight
  outright once it goes inactive, instead of leaving it frozen in place —
  confirmed against real gameplay (the field menu's party-status panel
  kept showing the previously-selected actor's highlight box after backing
  out of Skill/Equip/Status back to the command list). A prior pass had
  removed this exact gate on the theory that RPG_RT freezes rather than
  hides an inactive cursor; that theory does not hold up against genuine
  RPG_RT, so the gate is restored (`scripts/rpg2k_scene_check.rb`'s own
  check, which had pinned the frozen behavior, is flipped to match).
