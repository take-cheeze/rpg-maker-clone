- **The Equip screen now shows the highlighted item's description**, in a
  one-line banner across the very top of the screen. Found by comparing
  against a genuine `RPG_RT.exe` under wine: RPG_RT draws the database
  item's own `description` field there for whichever item is under the
  cursor (the slot's currently-equipped item, or the highlighted candidate
  while picking a replacement) -- `Scene::EquipMenu` drew no such banner at
  all. The fix also closes out a testing-infrastructure bug that had been
  blocking a clean wine capture of this screen: the retry loop used to
  detect "has the screen changed yet" by diffing the whole frame, which
  false-positived on the cursor itself moving between menu rows as often as
  on a real screen change. Narrowing the diff to just the menu's own region
  fixed that.
