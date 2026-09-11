- **Fixed the most severe real, live correctness bug found so far in the
  opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler.** Every SEND-name-extraction
  regex in `tools/bc2cpp/bc2cpp.rb` (four copies) omitted the bitwise/
  unary operator characters (`&`, `|`, `^`, `~`, `%`, and the unary-method
  suffix `@`), so a call site sending one of those names (`flags &
  DIR_BIT[dir]`, `index % list.size`, ...) matched no method name at all
  and silently compiled to `mrb_funcall(M, recv, "", ...)` -- an
  empty-string method name, a guaranteed `NoMethodError` at runtime,
  invisible to any compile-time check (the generated C++ compiled and
  linked clean either way). A direct grep of the real generated output
  found this live in **41 call sites across 32 already-shipped compiled
  methods spanning a dozen classes** -- overwhelmingly the `%`-for-
  cursor-wraparound idiom used by nearly every already-shipped menu's own
  scrolling-cursor/blink-arrow logic (`RPG2k::Scene::Order`/`EquipMenu`/
  `ItemMenu`/`SkillMenu`/`Menu`/`StatusMenu`/`DebugMenu`/`SaveLoad`/
  `Base`, `RPG2k::Window`, `Game::Screen`, `Game::Transition`), plus the
  triggering `&`/`|`/`~` bitwise flag work in
  `RPG2k::Scene::ChipsetEditor#toggled_byte`/`#cell_color_for`. Every one
  of these was silently generating a guaranteed crash the moment a player
  actually scrolled a list or moved a menu cursor -- this compiler's
  single highest-impact bug, precisely because the affected pattern is
  the most common UI idiom in the whole codebase, not an edge case. Fixed
  at the root (one character class, reused by every SEND-name extraction
  site); every affected class's own generated output regenerates
  correctly with the fix in place, verified by a direct before/after diff
  of the real generated code and a zero-match grep for the broken call
  shape post-fix. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
