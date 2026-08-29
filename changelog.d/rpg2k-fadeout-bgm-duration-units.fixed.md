- **Fade Out BGM no longer fades the music 100x too slowly.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: the event command's duration parameter is
  already milliseconds, passed straight through with no scaling. This build
  treated it as tenths of a second and multiplied by 100, turning an
  intended 0.8-second fade into an 80-second one.
