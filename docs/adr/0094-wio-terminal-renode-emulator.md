# 94. A Renode emulator for the Wio Terminal port

Date: 2026-09-07

## Status

Proposed — P1, P2 and P3 below are done and verified (see
`app/wio/renode/`). P4's own peripheral half turned out to already exist
upstream and needed no new code, but a platform-wide performance limitation
(delay()-bound wall-clock cost, found while pursuing P4 — see the P4 entry
and `app/wio/renode/README.md`) means its exit criteria is not met yet, and
is now this project's real blocker rather than any specific phase. P5 is
not started.

## Context

ADR 7 put the RPG2k runtime's HAL bring-up and the shared `wio_walk` map
engine (ADR 91) on real Wio Terminal hardware, and this project's first
confirmed run of either firmware on an actual board happened in the session
that also fixed `wio_walk`'s tile colours (see the changelog fragment
`wio-walk-first-hardware-run.fixed.md`). That session's colour bug is exactly
why an emulator is worth having: it was a SAMD51-specific quirk in
`TFT_eSPI::pushImage`'s bulk SPI transfer path, found only by flashing real
hardware three times and reading a physical screen between each attempt. CI
(`.github/workflows/build.yml`'s `wio` job) only compiles both firmware
environments — "this environment cannot cross-build or flash the board" is
stated outright in that job's own comment — so nothing catches a regression
here except a human with the board in hand. The ask this ADR answers: can we
get *some* of that feedback loop into CI/local dev without hardware, in
particular CPU-usage profiling of the render hot path (`draw_map` /
`rw_compose_cell` / `to565_push` / `pushImage`)?

**No off-the-shelf option covers this board.** Wokwi (the common
browser-based AVR/ESP32/STM32/RP2040 simulator) has no SAMD21/SAMD51 support
at all. [Renode](https://renode.io) (Antmicro's C#-based embedded simulator,
built for exactly this CI-without-hardware use case, with a scriptable
`.repl` platform-description format, a Robot Framework test harness, and a
built-in execution profiler — `machine EnableProfiler`, exercised by
`tests/unit-tests/profiler-trace.robot` upstream) is the closest fit, but as
shipped it only has a bare-bones `platforms/cpus/atsamd51g19a.repl`: a
Cortex-M4F core, one SERCOM UART, flash/RAM sized close to the Wio Terminal's
own budget, and three `Python.PythonPeripheral` register stubs to get a
*different* SAMD51 board (an Adafruit ItsyBitsy M4 running Zephyr) through
clock-tree bring-up. No Wio Terminal platform, no display, no SD, no buttons,
and Renode itself was not installed in this dev environment before P1 (it is
a standalone download, not a repo dependency — see `app/wio/renode/README.md`
for how to get it; nothing else here requires it).

**Peripheral-by-peripheral feasibility**, checked against the upstream
`renode/renode-infrastructure` source (not just documentation, since the
supported-boards list itself says it is incomplete):

| Peripheral | Upstream support | Verdict |
| --- | --- | --- |
| Cortex-M4F core, NVIC, flash/RAM | `platforms/cpus/atsamd51g19a.repl` | Reuse as a starting point |
| SERCOM UART | `UART.SAMD5_UART` | Reuse (already in the base platform) |
| SERCOM SPI | Nothing — `SPI.SAM_SPI` (`src/.../Peripherals/SPI/SAM_SPI.cs`) turned out to be the unrelated classic SAM4/SAME70 "SPI" peripheral (PDC DMA, write-protection registers, `SPI_SR`/`SPI_RDR`/`SPI_TDR`) — a different Atmel IP block, not SERCOM, register-for-register incompatible. **Verified wrong by reading the C# source before wiring it in**, not assumed; see below for what P2 actually used instead. | Genuinely nothing upstream models SERCOM at all, in any mode. |
| GPIO PORT (5-way switch, buttons, LCD D/C) | `GPIOPort.SAMD21_GPIO` (`src/.../Peripherals/GPIOPort/SAMD21_GPIO.cs`) | **Confirmed reusable as-is in P3**, for the LCD's D/C output pin specifically (PORTC.6) — instantiated directly at PORTC's SAMD51 base address with no changes needed. The 5-way switch/buttons (input pins, not yet exercised by any firmware's boot path up to `loop()`) remain unverified. |
| Clock tree (GCLK/OSCCTRL/MCLK) | Only the 3 stubs already in `atsamd51g19a.repl` (`gclk_phctrl1`, `pac_intflag`, `pac_status`) going in | **Confirmed in P1**: Arduino's `startup.c`/`wiring.c` need 9 register stubs total (the 3 above plus 6 more — see `app/wio/renode/wio_terminal.repl`), not an unbounded set. All 9 map to registers this repo's own read of the SAMD51 CMSIS headers named exactly, addressed from `startup.c`'s actual poll sites rather than guessed. |
| ILI9341/ST7789 SPI TFT display | Nothing upstream (confirmed: no `ILI9341`/`ST7789`/generic SPI-command-stream-to-framebuffer peripheral anywhere in `renode`/`renode-infrastructure`) | **Done in P3** — `Video.ILI9341_SPI` (`app/wio/renode/peripherals/Video/ILI9341_SPI.cs`), scoped to exactly `CASET`/`PASET`/`RAMWR` as planned. Verified correct directly, not just "it compiles": `app/wio/renode/lcd_smoke_test.resc` drives the registers by hand and the resulting PNG's pixels are exactly right (red/blue rows land in and stay bounded to the CASET/PASET window; ImageMagick-checked, see `app/wio/renode/README.md`). |
| SD card over SPI | **Wrong going in, corrected in P4**: this ADR originally said nothing upstream speaks SD's SPI-mode wire protocol, based on the class list and `SDCardExtensions.cs` alone. `SD.SDCard` itself, read directly, already has a `spiMode` constructor flag and a full `Transmit()`/SPI state machine (`WaitingForCommand`/`WaitingForArgBytes`/single- and multi-block read and write, R1 generation, the same command-byte bit-pattern check independently arrived at while first drafting a from-scratch replacement) — it is a general SD-over-SPI implementation, not SDIO-only. | **Nothing to write.** `SD.SDCard @ sercom6_spi` with `spiMode: true` is the whole of P4's peripheral half; `scripts/wio_renode_sdcard.bash` builds the FAT-formatted card image (`mkfs.vfat`/`mtools`) a real firmware's FAT driver needs to find files on. |
| DMA controller (DMAC) | Not checked yet | **Found in P2, not anticipated going in**: `wio`'s LVGL flush path uses `SPIClass::transfer`'s DMA-driven bulk mode (`Adafruit_ZeroDMA`), which spins forever on a "job done" flag nothing sets once a DMAC exists to set it. `wio_walk`'s single-byte blocking `SPI.transfer()` does not need this. Scope and upstream availability unassessed — a P3-adjacent gap, smaller than the ILI9341 peripheral itself but not yet sized. |

The peripheral picture changed in both directions once actually checked
against source and tried against real firmware, not just read about: SPI
looked free (`SAM_SPI`) and turned out to need writing from scratch, while
the clock tree looked open-ended and turned out to be exactly 9 stubs. The
lesson generalises — this ADR's own remaining size estimates (P3/P4 below)
carry the same "unverified until attempted" caveat the clock tree did before
P1, and should be treated that way rather than as settled.

## Decision

Build the emulator in phases, each with its own exit criteria, the same
shape ADR 7 used for the port itself — because the honest answer, like ADR
7's, is that nobody knows yet exactly how far the clock-tree stubbing in
Phase 1 goes until it is attempted against Renode directly, and this ADR
should not promise more certainty than that.

- **P0 — this ADR.** No emulator code lands with it.
- **P1 — CPU boots, no peripherals beyond UART. Done.** Vendored under this
  repo as `app/wio/renode/wio_terminal.repl` (not upstreamed to Renode's own
  tree — this board is not something Renode itself would carry). Forked
  from `platforms/cpus/atsamd51g19a.repl`, adding 9 register stubs Arduino's
  `SystemInit()`/`init()` need to get through the clock tree without
  spinning forever (each documented in the `.repl` file against the exact
  `startup.c` line and CMSIS register name it answers). All three firmware
  ELFs (`wio`, `wio_walk`, `wio_sd_upload`) reach their own `setup()`
  symbol — the originally-planned exit criteria ("the emulated UART shows
  expected output") turned out to be the wrong check: this board's Arduino
  `Serial` is native USB CDC, not the SERCOM UART the base platform models
  (that would be `Serial1`), so a symbol-address hook
  (`cpu0 AddHook <setup_addr> ...`) is what `app/wio/renode/boot.resc`
  actually uses. See `app/wio/renode/README.md` for the two non-obvious
  pitfalls found getting here (`flipflop` vs `counter` stub choice; one stub
  per register, not per peripheral).
- **P2 — GPIO + SPI wired up, no display/SD content yet. Substantially
  done.** Planned to reuse `SAM_SPI` and an adapted `SAMD21_GPIO`; `SAM_SPI`
  turned out to be the wrong peripheral entirely (see the table above), so
  P2 used the same register-stub approach as P1 instead — four more
  per-register stubs per SERCOM instance (`CTRLA`, `INTFLAG`, `SYNCBUSY`,
  `DATA`), for both SERCOM6 (`SDCARD_SPI`) and SERCOM7 (`LCD_SPI`) per the
  Wio Terminal Arduino variant's actual pin mapping. Exit criteria met for
  `wio`: it reaches **and keeps stably running** `loop()` (PC sampled across
  repeated `RunFor` calls stays in the expected polling addresses, not
  wedged on one instruction) — the SPI writes this ADR asked P2 to confirm
  complete, complete. `wio_walk` reaches `setup()` and is legitimately busy
  in a `millis()`-bounded SD retry timeout rather than hung, but was not run
  long enough to confirm it reaches `loop()` too (real-time cost, not a
  correctness question). GPIO/`SAMD21_GPIO` was never reached — nothing in
  any of the three firmwares' boot path up to `loop()` touches the button
  pins yet (they are read from inside `loop()` itself, on the next poll
  after the one sampled). **Also found, not planned for:** `wio`'s LVGL
  flush path needs a DMA controller model (see the table above) that
  nothing here provides yet — `loop()` runs, but the first real frame flush
  will spin forever once it's actually exercised past the point this session
  sampled it.
- **P3 — the ILI9341 framebuffer peripheral. Done, with a scope
  adjustment.** The peripheral itself (`Video.ILI9341_SPI`) landed as
  planned and is verified correct directly (see the table above and
  `app/wio/renode/README.md`), plus `SPI.SAMD51_SERCOM_SPI` — a real
  SERCOM-in-SPI-mode controller, replacing P2's per-register `flipflop`
  stubs for SERCOM6/7 with something that answers those same polls
  correctly *by construction* and actually delivers bytes to an attached
  device, which turned out to be necessary before any real peripheral could
  receive anything at all (register stubs have no bus underneath them to
  attach a device to). Building either meant building Renode from source
  (`scripts/wio_renode_build.bash`, pinned commit
  `ab721d88e135a1bcb8ed2ecc5a38f51cbe61fdd2`) since release binaries are
  precompiled — this repo's own nix devshell already had every prerequisite
  (cmake, gcc/g++) except the .NET 8 **SDK** (the portable release only
  bundles the runtime), a straightforward extra install.
  **What did not land**: driving the peripheral from real firmware instead
  of by hand. See P4 below — attaching a real SD card did not turn out to
  be the last piece.
- **P4 — the SD-over-SPI peripheral. Half the work turned out to already
  exist, and the other half is not the bottleneck it looked like.**
  `SD.SDCard` already implements a full SD-over-SPI state machine
  (`spiMode: true`) — checked directly this time (reading `Transmit()`
  itself, not just the class list, which is exactly the mistake that missed
  `SAM_SPI`'s SPI mode... in the other direction: this ADR said *nothing*
  spoke SPI-mode SD, and something did). Nothing needed writing; P4's actual
  new code is `scripts/wio_renode_sdcard.bash`, which builds a real
  FAT16-formatted disk image (`mkfs.vfat`/`mtools`) holding a real Nepheshel
  export and a `.repl` snippet wiring it onto `sercom6_spi`, layered onto
  the base platform with a second `LoadPlatformDescription` call (`.repl`
  files do not support `$variable` substitution the way `.resc` scripts do,
  so the image path — inherently environment-specific — cannot live in the
  committed `wio_terminal.repl`).
  **Attaching a real card did not unblock `wio_walk`'s render path.**
  Booting `wio_walk` with the card attached still does not reach `loop()`
  in any of the virtual-time budgets tried, up to 30 virtual seconds — which
  itself ran for roughly 5 real minutes before hitting an unrelated Renode
  bug (`ConsoleIOSource.HandleInput()` throwing an unhandled
  `SemaphoreFullException` on a long headless run with stdin redirected
  from `/dev/null` — a genuine upstream stability issue, not anything in
  this platform; see `app/wio/renode/README.md`). Register-level inspection
  at the point it gets stuck (`cpu0 AddHook`
  reading `r0`/`r1` at `SERCOM::transferDataSPI`, not just sampling `PC`,
  which the first attempt at this got wrong — reading a register the
  faulting instruction had not written yet, mistaken for corruption) shows
  it is genuinely processing real ILI9341 init traffic on `sercom7`
  (`LCD_SPI`), not SD, and not stuck on a bad address. The real cost is
  `app/wio/renode/README.md`'s delay()-cost finding applying somewhere new:
  `TFT_eSPI::init()` alone has ~295 ms of unconditional `delay()` calls
  *before* `SD.begin()` is ever reached, each costing the same
  disproportionate wall-clock time as `sdWait()`'s timeouts did, for the
  same underlying reason (no per-byte/per-instruction virtual-time cost
  anywhere in this platform). The original exit criteria ("`wio_walk` …
  renders the same map this session walked") is therefore still not met —
  not because the SD half is missing, but because *getting there at all*
  (LCD init, then SD init, then the actual file reads, then rendering) adds
  up to more delay-bound wall-clock cost than this session's budget covered.
- **P5 — profiling and CI wiring.** Use `machine EnableProfiler` (or
  instruction-count tracing) around one `draw_map()` call to get real
  cycle/instruction numbers for the render hot path, and decide whether any
  of P1–P4 is worth running in CI (a Robot Framework test, mirroring
  Renode's own `tests/platforms/atsamd51g19a.robot`) versus staying a local
  dev tool.

Each phase is independently useful and gate-able — P2 alone already answers
"does the firmware hang on this board's clock tree," which is a real
regression class distinct from the colour bug. Later phases are not blocked
on earlier ones being perfect, only booted.

## Consequences

- **Closes a real gap, partially.** The ILI9341 model (P3) is built and
  verified correct against hand-driven register writes, but not yet wired
  through real firmware end-to-end — so it does not yet catch a
  `pushImage`-style colour regression the way this ADR was originally
  motivated by, only proves the receiving end is trustworthy once something
  reaches it. Attaching a real SD card (P4) was expected to be what closed
  that last mile and was not: the actual bottleneck is `delay()`-bound
  wall-clock cost throughout the boot path (LCD init included, not SD
  specifically), a platform-wide property this ADR's phases do not fix by
  themselves.
- **One new C# peripheral landed in P3, none needed in P4.**
  `SAMD51_SERCOM_SPI` and `ILI9341_SPI` (`app/wio/renode/peripherals/`) are
  new code in Renode's own codebase — a different language and build
  system than this repo's C++, built via `scripts/wio_renode_build.bash`
  against a pinned upstream commit rather than vendored into a fork.
  Whether they eventually go upstream (contributed to `renode/renode`) is
  still an open question; for now they live in this repo and get copied in
  at build time. P4 needed no new peripheral at all — `SD.SDCard` already
  had one — so this ADR's "two new C# peripherals" framing for the whole
  project turned out to overstate the real cost by half.
- **Does not replace real-hardware testing.** An emulator that models
  "correct" ILI9341/SPI behaviour would *not* have caught this session's bug
  on its own — the bug was this specific `TFT_eSPI` fork's SAMD51-only
  behaviour diverging from the textbook. `ILI9341_SPI` was deliberately
  written to what this firmware's *actual* wire protocol is (plain
  MSB-first RGB565, matching `to565_push`'s corrected output, not a naive
  read of the format) rather than "textbook ILI9341," precisely so it would
  reproduce the corrected, real-hardware-verified image — but that
  correspondence itself is still only reasoned about, not confirmed by
  actually rendering the same frame both ways and diffing them, since
  firmware-driven rendering is what's still blocked. That comparison
  remains the real bar, the same way ADR 7's P1 exit criteria demanded real
  `size` numbers instead of estimates.
- **No commitment to CI yet.** P5 explicitly defers the "does this run in
  GitHub Actions" question — Renode is a real dependency to add to that
  environment (a few hundred MB, plus whatever runtime it needs), and that
  cost should be weighed once P1–P4 have proven the platform description
  actually works, not before.
- **Risk register:** the delay()-cost problem (see `app/wio/renode/
  README.md`) is now the single biggest open risk to this whole platform's
  usefulness for anything that needs to reach `loop()` reliably — it is not
  scoped to one phase, and P4 attaching a real card *disproved* the
  cheapest hoped-for fix (that success paths would just skip the slow
  parts); a real fix (a virtual-time-aware SPI cost, or a monitor-side
  time-warp) is now the clear next blocker, not a new peripheral. The
  newly-found DMAC gap has not been sized at all yet. P2's own experience
  (SPI looked reusable and was not; the clock tree looked open-ended and
  was exactly 9 stubs; P4's SD-over-SPI looked like new code and needed
  none) is a reminder that this ADR's own remaining size estimates keep
  being wrong in both directions, not just the pessimistic one — treat any
  that remain as unverified until attempted. This entire ADR's phases
  remain additive to, not a replacement for, testing on the real board this
  session used.
