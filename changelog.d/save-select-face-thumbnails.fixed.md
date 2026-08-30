- **The save/load file-select screen now draws each save slot's party face
  thumbnails**, not just the leader's name/level/HP text. `Game::State#to_lsd`
  already exported up to four members' `faceset_name`/`faceset_index` into
  the save's title chunk specifically so a real RPG_RT could show these
  (LCF save chunk 100, fields 21-28), but `Scene::SaveLoad#draw_slot_box`
  never read them back. Ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine: it crops a
  plain 48x48 FaceSet cell with no scaling and never mirrors it for this
  screen (unlike a message window's Change Face Graphic, which can), and
  draws up to four of them in a row at a 56px pitch. Fixed with a new `Scene::SaveLoad#draw_slot_faces`
  (plus `#load_face_bitmap`/`#build_face_cell`, mirroring `Scene::Map`'s own
  message-face helpers), drawing each of the slot's party members
  (`state.party.actors[0..3]`, seat order, the same order `#to_lsd` writes
  them in) right-anchored in the slot box at the same 56px pitch; a member
  with no FaceSet set (a blank name) simply leaves its slot empty. Covered
  by two new `scripts/rpg2k_scene_check.rb` checks (two distinct members'
  faces crop from their own FaceSet cell at the right position and pitch;
  a blank-named member and a 5th-and-beyond member both draw nothing),
  both confirmed to fail against the pre-fix code before the fix.
