- **The PSP EBOOT's idle "Keys:" status label no longer dereferences a
  null pointer when Square, L, R, Start, or Select is pressed.**
  `app/psp/main.cxx`'s `kKeyNames[PSP_INPUT_KEY_COUNT]` (36 entries) was
  only initialized with 7 strings ("Up"/"Down"/"Left"/"Right"/"A"/"B"/"C");
  the rest were implicitly null. `mruby-rgss/src/psp.cxx`'s
  `psp_input_scan()` sets mask bits 21-25 (`PSP_INPUT_N0`..`N4`) when
  those five buttons are pressed, and `show_keys()` looked up
  `kKeyNames[k]` for every set bit and passed it straight to
  `StrBuf::str()`, which dereferences its argument unconditionally —
  reachable in practice, confirmed interactively under PPSSPP's SDL
  frontend (`Bad memory access detected and ignored: 00000000` spamming
  on every affected keypress). Not caught by CI's `psp-smoke` job, which
  injects no controller input. Fixed by filling in every entry
  (`N0`-`N9`/`+`/`-`/`*`/`/`/`.` for the reachable ids, empty strings for
  the currently-unbound gap ids), plus skipping empty names in
  `show_keys()`'s loop. Also switched `show_keys`'s mask parameter from
  `uint32_t` to `uint64_t` (matching `psp_input_scan()`'s real return
  type) and its bit test to `1ull << k`: the old `uint32_t`/`1u << k`
  combination silently truncated the high bits of the mask on the call
  site's implicit narrowing conversion, and separately triggered
  undefined behavior for `k >= 32` regardless (both currently only
  affecting bit ids the HAL never actually sets, but worth closing while
  in this code).
