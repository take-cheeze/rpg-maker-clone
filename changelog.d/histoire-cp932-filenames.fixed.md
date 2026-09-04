- `scripts/download-histoire.bash` now repairs filenames after `lha`
  extracts `histoire203.lzh`: 208 of the archive's own art assets
  (`System/イストシステム3.png`, 23 `ChipSet/*.png` entries, dozens under
  `Picture/`, ...) are named in Shift_JIS, and unlike `unar -e cp932`
  (`download-killer-knights.bash`'s own fix for the same class of bug),
  `lha` has no filename-transcoding option at all — every one of those names
  landed on disk as raw Shift_JIS bytes, byte-identical mojibake on a UTF-8
  filesystem. `lcf_testbed_check.rb` and friends never noticed (none of them
  read a filename a game database points at), but actually booting the real
  engine against the game (`rpg2k_boot_check.bash`) showed every one of
  those 208 assets logging "not found" and falling back to the no-RTP
  degrade path (colour-block tiles, a plain window panel) even though the
  file was right there on disk, just under the wrong bytes. A small Python
  pass now walks the extracted tree bottom-up and renames each entry whose
  raw bytes decode as cp932, the same repair `unar -e cp932` does internally
  — confirmed by booting the built engine on the fixed extraction: the
  chipset/windowskin "not found" logs are gone, and the only degrade-path
  warnings left (`ChipSet/基本`, an SE named `剣1`) name assets genuinely
  absent from the archive, not shipped by this game and needing the RPG2000
  RTP instead — the same category of warning Nepheshel/mtf-meido-action
  already show without RTP installed.
