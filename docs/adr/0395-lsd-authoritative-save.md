# 0395. The .lsd is the authoritative save; chunk 200 carries the fields the liblcf chunks miss

Date: 2026-10-10

## Status

Accepted. Changes the save-format framing in docs/adr/0128 (its wio decision
stands; see Decision 4).

## Context

Until now a Save wrote two files: the portable Marshal dump `save<N>.mrb`, the
only exact copy of the game state, and a best-effort editor sibling
`Save<NN>.lsd` (`Game::State#to_lsd`) that real RPG_RT and editor tooling can
read. The `.lsd` was documented as dropping the game timer, the per-actor name
and title overrides of non-leader party members, and `save_count`.

Checking those three claims against the code (not the comments) changed the
picture:

- **Timers** already round-trip. Both `Game::Timer`s live in inventory chunk 109
  fields 23-30 (liblcf's `ChunkSaveInventory` ids 0x17-0x1E; see the changelog
  fragment `save-timer-lsd`), and `from_lsd` restores them.
- **Non-leader name and title overrides** already round-trip. Chunk 108
  (`SAVE_PARTY_ACTOR`) field 1 is the name, field 2 the title
  (`save-actor-name-override`, and the title check in
  `scripts/rpg2k_logic_check.rb`).
- **`save_count`** was written to the `.lsd` (system chunk 101 field 131) by
  `export_lsd`'s own argument. The only real bug was `to_lsd`'s default of `1`
  for a caller that omits it.

So the premise that the `.lsd` was missing those fields was stale. A field-by-field
audit of `Game::State#to_h` (the exact keys the Marshal dump carries) against a
`to_lsd`/`from_lsd` round trip found the fields that really were lost:

| `to_h` field | what the `.lsd` did |
| --- | --- |
| `weather` (type, strength) | not written at all |
| `encounter_total` | not written (only the map's `encounter_rate` was) |
| `boarded` (which vehicle the party is riding) | not written; the vehicle records' field 101 holds a constant type id, not a boarding state |
| `common_event_progress` | not written |
| `player_flash` power and total | only the derived current level and remaining frames; the peak duration and the exact power were lost (the old test asserted this as "no separate peak-duration field on the wire") |
| picture `opacity` / target opacity | quantised to chunk 103's 0..100 transparency (`200.25` came back as `198`) |
| an erased picture's `name` | dropped (chunk 103 drops it on erase, as RPG_RT does), but the Marshal dump keeps it |

The `.lsd` cannot carry these in its own schema without guessing RPG_RT's
meaning for them, so they go in a project-specific chunk.

## Decision

### 1. Chunk 200 carries the remaining fields

`SAVE_DATA` gets chunk 200 (`:lsd_ext`, declared `:int8_array`, so it is raw
bytes). Its payload is a list of records, `[BER tag][BER length][body]`:

| tag | body |
| --- | --- |
| 0 | version (1). Always written; the marker of this engine's own save |
| 1 | weather type, strength (BER) |
| 2 | encounter total (BER) |
| 3 | boarded vehicle type id, 0 = none (BER) |
| 4 | flash red, green, blue, frames, total (BER); power (8-byte double) |
| 5 | common-event progress: (event id, index) BER pairs |
| 6 | per picture: id, name (length-prefixed), opacity (double), target flag, target opacity (double) |

Doubles are `pack('E')`, exact in CRuby and mruby. Unknown tags are skipped on
read; an absent record keeps the field's default. Values are non-negative
(clamped on write), which every field here is.

`to_lsd` always writes the chunk. `from_lsd` applies it last
(`Game::State.apply_lsd_extension`), so its exact values replace the coarser
liblcf-chunk approximations. The picture restore mutates the existing `Picture`
(`restore_exact`) rather than rebuilding it with `Picture.from_h`, because a
rebuilt picture is always shown again and would drop an erased picture's state.

### 2. The save-slot policy

`RPG2k#save_game` (mruby-rpg2k/mrblib/main.rb):

- **Default:** writes `Save<NN>.lsd` only. It is authoritative. A failed write
  fails the save (returns false, logged). There is no silent Marshal fallback,
  because a fallback would leave a stale marked `.lsd` shadowing a newer `.mrb`.
- **Where the `.lsd` path does not exist (wio, see docs/adr/0128)**, or under the
  kill switch: writes the Marshal dump, and exports the `.lsd` beside it as before.

`RPG2k#load_save_state` (default order):

1. The slot's `.lsd`, if it carries this engine's marker (chunk 200, version
   record). It is read with `from_lsd`. A `.lsd` that fails to parse is logged and
   skipped, so the Marshal save below still applies.
2. The Marshal save `save<N>.mrb`, for old saves and the kill switch's saves.
3. A genuine editor `Save<NN>.lsd` (no marker), through `from_lsd`, as before.

Because an old `.lsd` export (no marker) never outranks a Marshal save, every
save written before this change loads exactly as it did.

### 3. Kill switch

`RPG2K_SAVE_MARSHAL_FIRST=1` in the environment restores the old Marshal-first
order for saves and loads. `src/main.cxx` reads it (mruby has no `ENV` for the Ruby
side, the same reason `RGSS_SCRIPT_HOST` is read there) and exposes the constant
`RPG2K_SAVE_MARSHAL_FIRST`. Unset, empty or `0` keeps the new default. The
Marshal-first path is still built and tested
(`scripts/rpg2k_lsd_authoritative_check.rb`, the kill-switch checks).

### 4. Wio: `from_lsd` is not restored

The task asked for `from_lsd` to come back on wio if its reason was gone. Its
reason, in docs/adr/0128, was the flash budget (the Wio Terminal's 507,904-byte
FLASH region, which 0128 and 0152 track), plus "no PC or editor to receive a
save". Restoring it is not a free change:

| measured with the host `mrbc --remove-lv` (4.0.0, pinned mruby + `patches/`) | bytes |
| --- | --- |
| `game/lsd_io.rb` on origin/master (excluded on wio today) | 24,414 |
| `game/lsd_io.rb` with this PR (the cost of restoring it on wio) | 28,512 |
| `main.rb` master / this PR | 23,292 / 24,280 (+988, on every target) |
| `schema.rb` blob, master / this PR | 22,498 / 22,513 (+15, on every target) |

- Restoring `from_lsd` on wio costs **+24,414 bytes** on the master code, or
  **+28,512 bytes** on this PR's code. Together with the +1,003 bytes this PR adds
  to wio's other files, the full wio delta against master is **+29,515 bytes** with
  restoration, or **+1,003 bytes** without.
- The margin left in the wio FLASH region could not be measured here. There is no
  `arm-none-eabi` toolchain in this sandbox, and the CI `wio` job was skipped on
  each of the last 12 master runs, so there is no recent `wio_size_report` to read.
  The CP932 table that a `MRUBY_TARGET=wio` build needs is not available either
  (docs/adr/0128).
- The "no PC" premise is weaker than 0128 said: the project already ships
  `scripts/wio_sd_upload.py` already puts files on the wio's SD card from a PC, so
  a PC-side exchange path exists, even if no save-file workflow uses it yet.

Because the margin is unknown and the reason (flash) was a hard budget, the
decision is to keep `from_lsd` excluded on wio and report the cost, not to force
it. Restoring it means removing the wio exclusion of `game/lsd_io.rb` in
`mruby-rpg2k/mrbgem.rake`, which is worth doing once a real wio link shows room
for about +28.5 KB.

## Consequences

- An engine save is now one file, `Save<NN>.lsd`, and a real RPG2000 editor can
  open it (for the fields it models; see the unverified point below).
- Old `save<N>.mrb` saves still load. They are not rewritten, and they are not
  deleted by a later save of the same slot (the marker, not the file's presence,
  decides which one loads).
- The LSD round trip is now field-for-field equal to the Marshal round trip for
  every `to_h` key the audit covers.
- `Game::State#to_lsd` now defaults `save_count` to the state's own counter.
- The `scripts/rpg2k_logic_check.rb` flash case now asserts the exact peak
  duration and power (it used to assert the lossy `total == frames`).
- wio: +1,003 bytes from this PR without restoring `from_lsd` (main.rb and the
  schema blob), and +29,515 bytes if it is restored.

### Verification

- `ruby scripts/rpg2k_lsd_authoritative_check.rb`: 24 checks pass. They cover
  Marshal-vs-LSD equality field by field for five populated states; dropping each
  of the six chunk-200 record kinds is caught (and dropping the version record
  removes the marker); a `.lsd` without chunk 200 loads with the old defaults; an
  unknown chunk id (201) survives an `LCF::SaveData` read and write byte for byte;
  and the save-slot policy (default writes the `.lsd` only, the kill switch writes
  the `.mrb`, both preferences, old saves, a wio-shaped state, a failed write, and a
  corrupt marked `.lsd` with a Marshal save beside it).
- Run against origin/master's own `mruby-rpg2k/` and `mruby-lcf/`, the same
  script fails its Marshal-vs-LSD checks and then aborts at load (its mutation
  table names the new constants), so it detects the old behaviour.
- `ruby scripts/rpg2k_logic_check.rb` (1201 checks), `ruby scripts/rpg2k_scene_check.rb`
  (1062 checks) and `ruby scripts/bc2cpp_lcf_schema_oracle_check.rb` (5415 reads
  inside the oracle) all pass.
- The field audit: a populated `Game::State` (party with overrides, timers, all
  switches and variables, pictures moving and erased, flash, weather, vehicles
  placed and boarded, message config, BGM and SFX slots, teleport and escape
  targets, tile substitutions) has zero differing `to_h` keys between its Marshal
  load and its LSD load.
- `mrbc --remove-lv` compiles every changed `.rb` and the regenerated schema blob.

### Not verified

- **RPG_RT's handling of chunk 200 is UNVERIFIED.** No genuine RPG_RT run is
  available here (the wine capture scripts need a game install this sandbox does
  not have). Whether RPG_RT ignores, preserves or rejects an unknown chunk id in a
  save is not known. Until a wine run is done, a `.lsd` written by this engine may
  not load in RPG_RT at all. This is the main risk of making it authoritative. The
  Marshal dump was the fallback for exactly this reason.
- **Unknown-chunk round trip** is verified for this repo's `LCF::SaveData`
  reader and writer only (`Array1D` keeps the raw bytes of every chunk id it reads,
  including ids the schema does not declare, and writes them back in ascending id
  order). It is not a claim about RPG_RT.
- **mruby runtime.** The changed Ruby is compiled by `mrbc` and the new codec was
  smoke-tested for `pack('E')` on the host `mruby`. The full checks were run under
  CRuby only, because the host mruby build lacks `mruby-stringio`.
- **`src/main.cxx`** is not built here: the desktop build needs SDL, lvgl and the
  rest of the native toolchain. The new code is a plain `getenv` and an
  `mrb_const_set`, next to the existing `RGSS_SCRIPT_HOST` and `RPG2K_*` ones.
- **wio** size is the mrbc-compiled size of the changed files, not a linked
  firmware. No `wio` or `wio_rgss_boot` link was run.
- **Picture state that is not in `to_h`** (for example the live tween
  position of a moving picture's `current_x`) is covered only by the existing
  chunk-103 tests, not by this check.
