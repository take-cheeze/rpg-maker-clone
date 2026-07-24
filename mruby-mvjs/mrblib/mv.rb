# RPG Maker MV support.
#
# Unlike the LCF makers (RPG Maker 2000/2003) and the RGSS makers (XP/VX), an
# MV game is a *JavaScript* application: its logic lives in `js/*.js` and runs
# on PIXI.js, and its database is `data/*.json`. Rather than reimplement that
# logic in mruby, we embed a real JavaScript engine (quickjs-ng) and run the
# game's own scripts unmodified, providing the browser/host environment they
# expect. See docs/adr/0004-javascript-maker-mv-quickjs.md for the full design.
#
# This class is the thin Ruby orchestration layer. It knows how to recognise an
# MV project and the order its scripts load, and it drives the boot handshake
# and per-frame pump. It deliberately does **not** parse or model game data in
# Ruby — the game's own JavaScript loads and interprets the JSON. The heavy
# lifting (the quickjs-ng host, the host-global shims and the Canvas2D -> Bitmap
# bridge) lands in the gem's C++ side in later milestones; the seams where it
# plugs in are marked `# M2/M3/M4:` below.
class MV
  # RPG Maker MV renders at 816x624 by default (the classic 4:3-ish MV canvas).
  WIDTH = 816
  HEIGHT = 624

  # The files that unambiguously mark a directory as an RPG Maker MV project:
  # the core engine script and the system database. (MZ uses `js/rmmz_core.js`
  # instead and is a separate, later target — see ADR 0004, milestone M6.)
  REQUIRED_MARKERS = ["js/rpg_core.js", "data/System.json"].freeze

  # The MV engine scripts, in the exact order the stock `index.html` loads them:
  # the vendored libraries first (PIXI and friends), then the engine modules,
  # then the game's plugin list and entry point. The embedded runtime evaluates
  # them in this sequence so the globals each script defines are visible to the
  # next, exactly as in a browser.
  CORE_SCRIPTS = [
    "js/libs/pixi.js",
    "js/libs/pixi-tilemap.js",
    "js/libs/pixi-picture.js",
    "js/libs/fpsmeter.js",
    "js/libs/lz-string.js",
    "js/libs/iphone-inline-video.js",
    "js/rpg_core.js",
    "js/rpg_managers.js",
    "js/rpg_objects.js",
    "js/rpg_scenes.js",
    "js/rpg_sprites.js",
    "js/rpg_windows.js",
    "js/plugins.js",
    "js/main.js",
  ].freeze

  class << self
    # The canonical MV script load order (see CORE_SCRIPTS).
    def core_scripts
      CORE_SCRIPTS
    end

    # Pure predicate: given the set of project-relative files that exist, is
    # this an MV project? Split out from `project?` so it can be exercised
    # without touching the filesystem.
    def satisfied?(present)
      REQUIRED_MARKERS.all? { |m| present.include?(m) }
    end

    # Does the directory look like an RPG Maker MV project?
    def project?(dir = GAME_DIR)
      REQUIRED_MARKERS.all? { |m| File.exist?("#{dir}/#{m}") }
    end

    # True once the embedded JavaScript runtime is available (defined by the
    # gem's C++ side in milestone M2). Until then the Ruby layer can be loaded
    # and tested, but a game cannot actually run.
    def runtime_available?
      const_defined?(:JS)
    end
  end

  def initialize(args)
    @args = args
    @game_dir = GAME_DIR
  end

  attr_reader :game_dir

  # Boot the game: evaluate the MV core scripts in order inside the embedded
  # runtime, then hand control to the per-frame pump. Until the runtime lands
  # (M2) this reports the pending state instead of failing hard, so the rest of
  # the binary — and the other makers — are unaffected.
  def start
    unless self.class.runtime_available?
      warn_runtime_pending
      return
    end

    boot # M2/M3: create the JS host, install host globals, eval CORE_SCRIPTS
    loop { main_loop }
  rescue RGSS::Timeout
    # The engine raises this to unwind the run loop cleanly (e.g. --timeout_ms).
  end

  # One iteration of the host loop: pump the game's requestAnimationFrame/timer
  # queue once, then advance input and present the frame. Under Emscripten the
  # browser owns the outer loop and calls this directly (as it does for RPG2k).
  def main_loop
    unless self.class.runtime_available?
      warn_runtime_pending
      return
    end

    pump_frame # M3: run the rAF/timer queue for one frame
    RGSS::Input.update
    RGSS::Graphics.update
  end

  private

  # M3: install the browser/host globals (window/document/navigator/rAF/XHR/…)
  # and evaluate the MV core scripts in CORE_SCRIPTS order inside the JS host.
  def boot
    raise NotImplementedError, "MV.boot requires the embedded runtime (M2/M3)"
  end

  # M3: advance the game's requestAnimationFrame/timer queue by one host frame.
  def pump_frame
    raise NotImplementedError, "MV.pump_frame requires the embedded runtime (M3)"
  end

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[MV] RPG Maker MV support is under construction: the embedded " \
                 "JavaScript runtime (quickjs-ng) is not built into this binary " \
                 "yet. See docs/adr/0004-javascript-maker-mv-quickjs.md."
  end
end
