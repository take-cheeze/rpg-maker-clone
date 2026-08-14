- **The save-file-select screen's layout now matches genuine RPG_RT.exe.**
  Verified under wine: RPG_RT shows one bordered box per slot (name and
  level+HP only, a compact cursor around just the "File N" label, exactly 3
  slots visible at once, no placeholder text on an empty slot), where this
  engine packed more into one shared list window (gold, the current map,
  `/max` on HP, zero-padded labels, "-- No Data --" placeholders, 6 slots
  without scrolling). `Scene::SaveLoad` now builds one window per visible
  slot instead of a single list window, matching the reference capture
  field-for-field.
