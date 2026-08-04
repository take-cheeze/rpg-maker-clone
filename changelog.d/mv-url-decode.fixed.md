- MV now finds assets whose filenames are percent-encoded. MV builds every
  image/asset URL with `encodeURIComponent(filename)`, so a `$`-prefixed
  character sheet (`$Hero` → `%24Hero.png`), a `!`-prefixed object character
  (`%21…`), or any filename with a space (`%20`) reached our file loader still
  encoded and failed to open — silently falling back to a 1×1 empty bitmap, so
  those sprites rendered invisible. `mv_resolve_path` now url-decodes `%XX`
  escapes before touching the filesystem, so `$`/`!` character sheets and
  spaced filenames load. This is common in real MV games (big-character sheets
  use the `$` prefix). Unit-tested in `mruby-mvjs/test/canvas_test.rb`.
