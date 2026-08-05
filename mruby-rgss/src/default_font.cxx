// Locating the bundled default UI font (assets/fonts, see its README.md).
//
// A project that ships no font of its own would otherwise have every window
// drawn with the 12px shinonome bitmap font regardless of the size it asked
// for. This finds a fallback face for those projects; the RGSS text renderer
// (lib.cxx) reaches it through RGSS::Font.default_path, and the MV/MZ canvas
// (mruby-mvjs) calls default_font_path directly.
//
// Deliberately dependency-free: this gem is also built for the terminal-only
// and Emscripten variants, so the search is plain POSIX directory reading plus
// whatever directory the executable hands in (see default_font.hxx).

#include "default_font.hxx"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <dirent.h>

namespace rgss {
namespace {

// Filled by the executable before the first lookup; empty in the gem's own test
// build and on the embedded targets, which fall through to the candidates
// below.
std::vector<std::string> g_app_dirs;

// opendir/fopen rather than stat: the embedded targets (Wio, PSP) build this
// gem too, and both already have to provide the directory and stdio calls the
// rest of it uses.
bool is_dir(const std::string& path) {
  if (path.empty())
    return false;
  DIR* d = ::opendir(path.c_str());
  if (!d)
    return false;
  ::closedir(d);
  return true;
}

bool is_readable_file(const std::string& path) {
  if (path.empty())
    return false;
  std::FILE* f = std::fopen(path.c_str(), "rb");
  if (!f)
    return false;
  std::fclose(f);
  return true;
}

bool has_font_ext(const std::string& name) {
  if (name.size() < 4)
    return false;
  std::string ext = name.substr(name.size() - 4);
  for (char& c : ext)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return ext == ".ttf" || ext == ".otf" || ext == ".ttc";
}

// First font file in `dir`, or "". readdir order is arbitrary, so pick the
// lexicographically smallest name rather than whichever the filesystem happens
// to hand back first: a directory holding a hand-dropped extra face must
// resolve to the same font on every run.
std::string first_font_in(const std::string& dir) {
  DIR* d = ::opendir(dir.c_str());
  if (!d)
    return std::string();
  std::string found;
  while (dirent* e = ::readdir(d)) {
    const std::string name = e->d_name;
    if (!has_font_ext(name))
      continue;
    if (found.empty() || name < found)
      found = name;
  }
  ::closedir(d);
  return found.empty() ? found : dir + "/" + found;
}

std::string probe() {
  // An explicit override is the user's choice and wins outright; it may name
  // the font file itself or a directory to search.
  if (const char* env = std::getenv("RPG_DEFAULT_FONT")) {
    const std::string path = env;
    // fopen on a directory succeeds on some platforms, so rule that out
    // first rather than treating it as the font file.
    if (!is_dir(path) && is_readable_file(path))
      return path;
    if (is_dir(path)) {
      const std::string found = first_font_in(path);
      if (!found.empty())
        return found;
    }
  }

  std::vector<std::string> dirs = g_app_dirs;
  // The Emscripten preload mount (WASM_DEFAULT_FONT in CMakeLists.txt).
  dirs.push_back("/fonts");
  // Running from the source tree / from beside an unpacked build.
  dirs.push_back("assets/fonts");

  for (const std::string& dir : dirs) {
    const std::string found = first_font_in(dir);
    if (!found.empty())
      return found;
  }
  return std::string();
}

// Resolved lazily and then cached: the search is only a handful of
// opendir/readdir calls, but the RGSS text path asks for the fallback on every
// draw.
bool g_resolved = false;
std::string g_path;

}  // namespace

void add_default_font_dir(const std::string& dir) {
  g_app_dirs.push_back(dir);
  // Startup order is the executable's business, not ours; drop any answer
  // cached before this so a lookup during boot cannot pin the wrong one.
  g_resolved = false;
  g_path.clear();
}

const std::string& default_font_path() {
  if (!g_resolved) {
    g_path = probe();
    g_resolved = true;
  }
  return g_path;
}

}  // namespace rgss
