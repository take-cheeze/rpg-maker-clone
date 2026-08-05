// The bundled default UI font: the font used when a project ships none of its
// own. Downloaded into assets/fonts by scripts/download-default-font.bash (see
// that directory's README.md), so it is normal for it to be absent.
//
// The lookup lives in mruby-rgss because that is where text is rasterised, but
// the executable knows paths the gem cannot — it is also built for the
// terminal-only and Emscripten variants and must stay free of build-system
// wiring — so the executable hands its build/install directory in through
// set_default_font_dir.
#pragma once

#include <string>

namespace rgss {

// Add a directory to look in, ahead of the built-in candidates and in the order
// added. Called at startup by the executable with the locations its build baked
// in (<prefix>/share/rpg-maker-clone/fonts once installed, and the source
// tree's assets/fonts). A directory that does not exist, or that holds no font,
// is harmless: the search falls through to the next candidate.
void add_default_font_dir(const std::string& dir);

// Path to the default font file, or "" when none is installed. Resolved once
// on the first call, in this order:
//
//   1. $RPG_DEFAULT_FONT   -- a font file or a directory holding one, the
//                             user's override, so it always wins
//   2. the directories from add_default_font_dir
//   3. /fonts              -- the Emscripten preload mount (WASM_DEFAULT_FONT)
//   4. assets/fonts        -- relative to the working directory
const std::string& default_font_path();

}  // namespace rgss
