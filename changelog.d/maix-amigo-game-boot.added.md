- **Maix Amigo game boot**: the `maix_game` firmware boots the synthetic
  `data/maix-hello` game (new generator script) to its RPG2k title screen
  from flash-resident storage, proven under Renode by scene marker and
  title-framebuffer check in `maix-smoke`. Includes two firsts: setjmp
  exceptions for the target (the link drops `.eh_frame`) and a yielding
  stub `RGSS::Profiler`. See `app/maix/README.md`.
