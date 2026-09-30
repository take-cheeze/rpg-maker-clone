# Running the smoke suites with NOMETHOD_VERIFY

A closed-world build (`psp`, `wio`, `maix`) compiles some guard-chain fallbacks
proven dead into `bc2cpp_nomethod` (ADR 0210). In a normal build such a site
dispatches, then raises `NoMethodError`, or a "closed-world proof violated"
`RuntimeError` if the method exists after all (ADR 0262). Both are ordinary Ruby
exceptions, which a game `rescue` can hide.

Verify mode (ADR 0275) is an opt-in build in which reaching such a site is fatal:

```
bc2cpp: NOMETHOD_VERIFY: dead site reached: Game::Actor#hp (0 arg(s))
```

followed by `abort()`, with no dispatch first. Use it to test a dead-code proof
against real play: a smoke run that finishes has never reached a dead site.

## Turning it on

Set `BC2CPP_NOMETHOD_VERIFY=1` in the environment of the build. `build_config.rb`
then adds `-DBC2CPP_NOMETHOD_VERIFY` to the C++ flags of `rpg_maker_gems` builds.
Build into a fresh build directory: the generated files do not change, but object
files do not depend on the flag.

The hot-only list (ADR 0214) currently compiles none of the dead sites, so verify
mode is a no-op unless the build also compiles them: add `BC2CPP_HOT_ONLY=0`
(ADR 0226 counts about 3,000 sites, which is a large firmware).

```
BC2CPP_NOMETHOD_VERIFY=1 BC2CPP_HOT_ONLY=0 <the job's usual build command>
```

## Smoke suites

The `.github/workflows/build.yml` jobs that boot a closed-world firmware are the
ones to run this against: `psp` then `psp-smoke` (PPSSPP headless), `maix` then
`maix-smoke` (Renode), and the `wio` / `wio-renode` pair. Rebuild the firmware
job's artifact with the two variables set and run the smoke job unchanged. A
failure shows as the smoke job's firmware stopping (no bring-up heartbeat) with
the line above on stderr or the emulator's console. `abort()` needs a libc with
`stderr`; on a target where that line is not visible, the emulator stopping at
`abort` is the signal.

The desktop and wasm builds use the interpreter fallbacks for the same Ruby and
have no `bc2cpp_nomethod` sites (they are not closed-world builds), so verify
mode changes nothing there.

## Checking the helper itself

`scripts/bc2cpp_nomethod_verify_check.rb` builds the emitted helper against a real
mruby core in both modes and asserts normal mode dispatches then raises, and
verify mode aborts naming the site without running the method.
