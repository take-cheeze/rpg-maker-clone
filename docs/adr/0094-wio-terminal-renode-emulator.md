# 94. A Renode emulator for the Wio Terminal port

Date: 2026-09-07

## Status

Proposed

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
and Renode itself is not installed in this dev environment yet.

**Peripheral-by-peripheral feasibility**, checked against the upstream
`renode/renode-infrastructure` source (not just documentation, since the
supported-boards list itself says it is incomplete):

| Peripheral | Upstream support | Verdict |
| --- | --- | --- |
| Cortex-M4F core, NVIC, flash/RAM | `platforms/cpus/atsamd51g19a.repl` | Reuse as a starting point |
| SERCOM UART | `UART.SAMD5_UART` | Reuse (already in the base platform) |
| SERCOM SPI | `SPI.SAM_SPI` (`src/.../Peripherals/SPI/SAM_SPI.cs`) | **Exists** — the SAM family shares one SERCOM IP block across UART/SPI/I2C modes, and this is the SPI-mode model. The single biggest unknown we had going in (write a no-op SPI stub) turns out to already be a real peripheral upstream. |
| GPIO PORT (5-way switch, buttons) | `GPIOPort.SAMD21_GPIO` (`src/.../Peripherals/GPIOPort/SAMD21_GPIO.cs`) | SAMD21, not SAMD51, but Microchip kept the PORT register layout compatible across the SAM D2x/D5x families — likely reusable with at most a register-map diff, not a rewrite. |
| Clock tree (GCLK/OSCCTRL/MCLK) | Only the 3 stubs already in `atsamd51g19a.repl` (`gclk_phctrl1`, `pac_intflag`, `pac_status`) | Zephyr's SAMD51 clock init apparently needed only these three; Arduino's `startup.c`/`clock.c` touches a heavier set (DFLL48M, external 32 kHz crystal, USB clock) that we will only fully know by attempting the boot and stubbing whatever it spins on next — this is the main source of open-ended risk in Phase 1. |
| ILI9341/ST7789 SPI TFT display | **Nothing** — no `ILI9341`/`ST7789` peripheral anywhere in `renode` or `renode-infrastructure`, and no generic "SPI command stream → framebuffer" peripheral either | New peripheral, written by us. Scope is bounded by what this firmware actually sends: `TFT_CASET`/`TFT_PASET`/`TFT_RAMWR` (`0x2A`/`0x2B`/`0x2C`) plus the init command list `ILI9341_Init.h` already writes once at boot — track the address window, accumulate RGB565 pixels into a framebuffer, expose it as a PNG/BMP dump (Renode has `Video.` peripherals with framebuffer export elsewhere to model this on). We do **not** need to interpret every ILI9341 command, only the ones this firmware issues. |
| SD card over SPI | `SD.SDCard`/`SDCardExtensions.cs` model the **card** (block storage + CID/CSD, already used by every SDIO/eMMC controller upstream: `LiteSDCard`, `STM32SDMMC`, `NXP_uSDHC`, …) but nothing speaks **SD's SPI-mode wire protocol** (`CMD0`→idle, `CMD8`, `CMD55`+`ACMD41`→ready, `CMD17`/`CMD24` single-block read/write, R1 response byte, `0xFE` data token) — that framing is a different, smaller thing than an SDIO controller and does not exist upstream | New peripheral, written by us, but a *thin* one: it sits on `SAM_SPI`'s bus, decodes the SPI-mode command bytes, and drives the existing `SD.SDCard` object — the hard part (interpreting a raw card image) is already implemented upstream, we only write the wire framing. |

This is materially less new work than it looked like before checking the
source: two of the four missing pieces we expected to write from scratch
(SPI, GPIO) already exist upstream, and the SD gap is protocol framing over
an existing card model rather than a full storage stack.

## Decision

Build the emulator in phases, each with its own exit criteria, the same
shape ADR 7 used for the port itself — because the honest answer, like ADR
7's, is that nobody knows yet exactly how far the clock-tree stubbing in
Phase 1 goes until it is attempted against Renode directly, and this ADR
should not promise more certainty than that.

- **P0 — this ADR.** No emulator code lands with it.
- **P1 — CPU boots, no peripherals beyond UART.** Install Renode locally.
  Fork `platforms/cpus/atsamd51g19a.repl` into a Wio Terminal platform
  (`platforms/boards/wio_terminal.repl` in Renode's own tree, or vendored
  under this repo — TBD in P1 itself). Flash the *actual* `wio_sd_upload` or
  `wio` ELF (already built by CI) and get through Arduino's `init()` far
  enough to reach `setup()`, adding clock-tree register stubs one hang at a
  time. Exit criteria: the firmware reaches `setup()` and the emulated UART
  shows expected output (`wio_sd_upload` is the natural first target — it is
  the smallest firmware and already has a request/response protocol over
  Serial to assert against).
- **P2 — GPIO + SPI wired up, no display/SD content yet.** Add `SAM_SPI` and
  an adapted `SAMD21_GPIO` to the platform; confirm the 5-way switch reads as
  released and the TFT/SD SPI writes complete (i.e. `pushImage`'s blocking
  transfer returns) without needing real devices on the bus yet. Exit
  criteria: `wio` (the LVGL bring-up firmware) runs its main loop under
  Renode without hanging.
- **P3 — the ILI9341 framebuffer peripheral.** Write the scoped SPI-command
  → framebuffer peripheral described in the table above. Exit criteria: a
  `wio_walk` frame rendered under Renode can be dumped to a PNG and compared
  pixel-for-pixel against what this session verified by eye on real
  hardware — this is the check that would have caught the `pushImage`
  byte-order bug without a board.
- **P4 — the SD-over-SPI peripheral.** Write the wire-protocol framing over
  `SD.SDCard`, backed by a real exported `map.bin`/`tiles.bin` pair (from
  `scripts/export_nano7_map.rb`) as the card image. Exit criteria: `wio_walk`
  boots under Renode with no hardware at all, reads the real Nepheshel export
  off the emulated card, and renders the same map this session walked.
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

- **Closes a real gap, partially.** Once P3 lands, colour/rendering
  regressions in the `pushImage` path — the exact bug this session spent most
  of its time on — become catchable by CI or a local Renode run, not only by
  a human with a board. P4 extends that to the SD-backed map-loading path
  too.
- **Two new C# peripherals are the real cost.** The ILI9341 framebuffer model
  (P3) and the SD-SPI framing model (P4) are new code in Renode's own
  codebase (or a local fork/plugin of it), not this repo's C++ — a different
  language and build system, and a dependency this repo has not carried
  before. Whether they live upstream (contributed to `renode/renode`) or as a
  local-only patch is an open question for whoever picks up P3.
- **Does not replace real-hardware testing.** An emulator that models
  "correct" ILI9341/SPI behaviour would *not* have caught this session's bug
  on its own — the bug was this specific `TFT_eSPI` fork's SAMD51-only
  behaviour diverging from the textbook. The framebuffer model in P3 needs to
  match what this firmware's *actual* library does, which means P3's
  correctness itself should be checked against a real board at least once,
  the same way ADR 7's P1 exit criteria demanded real `size` numbers instead
  of estimates.
- **No commitment to CI yet.** P5 explicitly defers the "does this run in
  GitHub Actions" question — Renode is a real dependency to add to that
  environment (a few hundred MB, plus whatever runtime it needs), and that
  cost should be weighed once P1–P4 have proven the platform description
  actually works, not before.
- **Risk register:** the clock-tree stubbing in P1 is open-ended until
  attempted (Arduino's SAMD `init()` is heavier than the Zephyr shell the
  existing base platform was proven against); P3 and P4 are new Renode
  peripherals with no upstream precedent for either the ILI9341/ST7789
  interaction pattern or SD-over-plain-SPI, so estimate accordingly; and this
  entire ADR's phases are additive to, not a replacement for, testing on the
  real board this session used.
