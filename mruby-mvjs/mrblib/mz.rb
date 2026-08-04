# RPG Maker MZ support (foundation — milestone M6.1).
#
# MZ is the JavaScript maker family's newer member: like MV it is a *JavaScript*
# application with a `data/*.json` database, and it runs on the same embedded
# quickjs-ng host, host-global shims and IO/input/audio bridges that MV already
# uses (see mruby-mvjs and docs/adr/0004-javascript-maker-mv-quickjs.md). Two
# things set it apart:
#
#   1. Its engine scripts are `js/rmmz_*.js` (not MV's `js/rpg_*.js`), loaded in
#      a slightly different order (pako/localforage/effekseer instead of MV's
#      lz-string), and a community MIT reimplementation exists
#      (github.com/stak/rmmz-corescript), so an MZ test bed is authorable the
#      same way `data/mv-sample` is for MV.
#   2. It ships **PIXI v5, which is WebGL-only** — there is no Canvas2D renderer
#      to map onto the `Canvas2D -> Bitmap` bridge MV drives. Rendering therefore
#      needs a WebGL-subset backend on LVGL, which is the bulk of milestone M6
#      and is **not built yet**.
#
# So this class is the M6.1 foundation, mirroring MV's original M1: it recognises
# an MZ project and knows the canonical script load order, and reports the
# pending WebGL backend cleanly instead of misbehaving when the binary is pointed
# at an MZ game. The host reuse (M6.2) and the WebGL renderer (M6.3) land later.
class MZ
  # RPG Maker MZ renders at 816x624 by default, same nominal canvas as MV.
  WIDTH = 816
  HEIGHT = 624

  # The files that unambiguously mark a directory as an RPG Maker MZ project:
  # the core engine script and the system database. MV uses `js/rpg_core.js`
  # instead, so the two never collide.
  REQUIRED_MARKERS = ["js/rmmz_core.js", "data/System.json"].freeze

  # The MZ engine scripts, in the order the stock `index.html` loads them: the
  # vendored libraries first (PIXI v5, then pako for save compression,
  # localforage for storage, and Effekseer for animations), then the engine
  # modules, then the game's plugin list and entry point. As on the MV side the
  # runtime prefers the game's own `index.html` when present and only falls back
  # to this list, so it need only be the canonical default.
  CORE_SCRIPTS = [
    "js/libs/pixi.js",
    "js/libs/pako.min.js",
    "js/libs/localforage.min.js",
    "js/libs/effekseer.min.js",
    "js/libs/vorbis.js",
    "js/rmmz_core.js",
    "js/rmmz_managers.js",
    "js/rmmz_objects.js",
    "js/rmmz_scenes.js",
    "js/rmmz_sprites.js",
    "js/rmmz_windows.js",
    "js/plugins.js",
    "js/main.js",
  ].freeze

  class << self
    # The canonical MZ script load order (see CORE_SCRIPTS).
    def core_scripts
      CORE_SCRIPTS
    end

    # Pure predicate: given the set of project-relative files that exist, is this
    # an MZ project? Split out from `project?` so it can be exercised without
    # touching the filesystem (see mruby-mvjs/test/mz_test.rb).
    def satisfied?(present)
      REQUIRED_MARKERS.all? { |m| present.include?(m) }
    end

    # Does the directory look like an RPG Maker MZ project?
    def project?(dir = GAME_DIR)
      REQUIRED_MARKERS.all? { |m| File.exist?("#{dir}/#{m}") }
    end

    # False until the WebGL-subset backend PIXI v5 needs (milestone M6) is built.
    # The quickjs host itself is already present (it is shared with MV), but MZ
    # cannot render a frame without WebGL, so a whole game cannot yet boot.
    def runtime_available?
      false
    end
  end

  def initialize(args)
    @args = args
    @game_dir = GAME_DIR
  end

  attr_reader :game_dir

  # Native entry point. Until the WebGL backend lands (M6), this reports the
  # pending state instead of failing hard, so the rest of the binary — and the
  # other makers — are unaffected.
  def start
    warn_runtime_pending
  end

  # Per-frame entry point (Emscripten drives this directly, as for the other
  # makers). A no-op beyond the pending notice until M6 lands.
  def main_loop
    warn_runtime_pending
  end

  private

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[MZ] RPG Maker MZ support is under construction: MZ ships " \
                 "PIXI v5 (WebGL-only), and the WebGL-subset backend it needs " \
                 "is not built into this binary yet. The engine/host/IO/input/" \
                 "audio layers are shared with MV; only the renderer is " \
                 "missing. See docs/adr/0004-javascript-maker-mv-quickjs.md (M6)."
  end
end
