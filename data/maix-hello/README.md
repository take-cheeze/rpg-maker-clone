# maix-hello: the minimal synthetic RPG Maker 2000 game

The game the Maix Amigo port boots to its title screen (see
`app/maix/README.md`). Nothing here is vendored from any real game.

## Contents

- `RPG_RT.ldb` (56 bytes) — System section (title graphic `maix`,
  everything else default) + Terms section (`New Game` / `Continue` /
  `Shutdown` in ASCII, so the embedded shinonome font covers every glyph).
- `RPG_RT.lmt` (23 bytes) — empty property table, empty tree, start
  position (map 1, 8,10) for the future New Game slice.
- `Title/maix.png` (787 bytes) — 320x240 solid teal with a white border
  (orientation proof on a panel whose rotation is still open).

## Regenerating

```sh
ruby scripts/gen-maix-hello-game.rb [OUT_DIR]
```

Built with the project's own LCF reader/writer sources (loaded the way
`scripts/lcf_testbed_check.rb` loads them), so the output is parseable by
the firmware's identical reader by construction; the title picture is a
minimal stdlib-only PNG. The title scene degrades gracefully without
anything else (nil picture/skin/music/se all have blank fallbacks), so
this is everything it reads.
