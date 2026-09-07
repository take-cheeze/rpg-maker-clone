# 72. WOLF RPG Editor Sound(140): BGM/BGS by system-database selection

Date: 2026-09-07

## Status

Accepted

## Context

ADR 0071 implemented Sound(140)'s "play an SE by literal filename"
combination and left BGM/BGS entirely unimplemented -- the sample game's
own data had no BGS example at all, and its BGM examples all used the
"direct system-database selection" sound type (not Filename), whose
argument layout was not yet cross-checked.

Two more pieces fell into place investigating this:

- Help/05systemtype.html documents the system database's own type 1
  ("BGMリスト") and type 2 ("BGSリスト") tables in full: field 0 filename,
  field 1 playback volume% (0 = the file's own default), field 2 playback
  frequency% (0 = the same), field 3 loop start position in milliseconds --
  and the manual's own `Sound`(140) page (help/04ev_sound.html) says
  volume/frequency are settable *only* in Filename mode, meaning a
  database-selection call always uses the table's own stored values.
- `mruby-wolf`'s own `Wolf::Project#system_db` (and `DBType#value`) already
  reads this table for every project -- resolving a database-entry sound
  call needed no new data-layer work, just a lookup by index.

Cross-checking end to end against the sample game's own real data (ADR
0071's own byte-decode already found these two `Sound` calls in `map1
ev#13`, back to back) turned out unusually clean: entry 1's *own name* in
that BGM table, read straight from the database, is literally
"スタッフロール" (staff roll) -- and the very next thing that same script
does is show its own staff-roll credits. The other real call's own
`systemdb_entry` (`0xFFFF` as signed 16-bit = -1) matches the manual's own
documented "(停止)" [stop] sentinel for the database-selection dropdown,
immediately following the first.

## Decision

- `Wolf::Project::SYS_BGM_LIST`/`SYS_BGS_LIST` (system database types 1/2)
  join the existing `SYS_MAP_SETTINGS`/`SYS_POSITIONS`/`SYS_CHARACTER_
  IMAGES` constants.
- `Wolf::Interpreter#exec_sound_track_db_entry` handles `Sound`(140)'s
  BGM/BGS + database-selection combination: on the `-1` stop sentinel it
  calls `WolfRPG::MapScene#stop_track`; otherwise it looks the entry up in
  the matching table, and -- only when a real row exists -- calls
  `#play_track` with the table's own filename/volume/frequency (0 mapped
  to `RGSS::Audio`'s own 100 default, matching the manual's documented
  "0 means default"). A missing row, an unrecognised argument count (only
  4 is confirmed -- both real examples have exactly that), or a variable-
  named sound source remain logged and skipped, the same discipline ADR
  0071 already established for this command.
- Playback snaps immediately; the fade-time argument (present, identical
  across both real examples, but with no confirmed unit) is read by
  neither method, the same simplification already applied to Picture
  (150)'s own `process_time`.

## Consequences

- The sample game's own end-credits sequence (`map1 ev#13`) now actually
  starts its own staff-roll BGM and stops it, verified against the real
  database entry whose own name matches the surrounding script's intent.
- BGS itself is still unverified against any real example (none exists in
  the sample game's own data) -- implemented by direct symmetry with BGM's
  own confirmed layout (the manual and the wolfrpg-map-parser crate both
  treat the two identically; only the target `RGSS::Audio` method and
  system-database type differ), not independently cross-checked.
- Still unimplemented: a variable-named BGM/BGS source, a Filename-mode
  BGM/BGS call (whose own trailing-argument layout ADR 0071 already
  decoded structurally -- fade time, mid-position, pan, volume, frequency,
  loop start -- but has no real example with non-default values to confirm
  slot order against), preload/free-memory, BGS channels, and every
  documented "hidden feature".
