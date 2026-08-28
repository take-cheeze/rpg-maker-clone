- **RPG2003's Change Class command no longer swallows a dangling class id
  with no trace.** A database shrink can leave the id it targets pointing
  at a class (chunk 30) that no longer exists — shown as "?" in the editor,
  the exact shape docs/TODO.md's runtime error catalog already reports for
  the sibling hero/skill/item/enemy/enemy-group/battle-animation/terrain/
  chipset/common-event lookups, but "class" was never among them.
  `Game::Actor#change_class` now logs a `[RPG2k] Change Class: class #<id>
  not found in database, actor left unchanged` diagnostic before its
  existing early return, `respond_to?`-guarded the same way those sibling
  diagnostics are so a database with no class table at all (every RPG2000
  project, and any bare test fixture) stays quiet — this only fires for a
  genuine dangling reference in a database that does carry a class table.
  Behaviour is otherwise unchanged: the command was already a correct,
  harmless no-op for that actor either way, only the missing trace is new.
