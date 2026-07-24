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

    # True once the embedded JavaScript engine (`MV::JS`) is compiled into the
    # binary — i.e. the gem's C++ side (quickjs-ng, milestone M2) is present.
    # This proves JavaScript can be evaluated; it does not by itself mean a
    # whole game can boot (that needs the host globals + rendering of M3/M4).
    def js_available?
      const_defined?(:JS)
    end

    # True once a full MV game can boot end-to-end. The host globals, asset IO,
    # event loop, saves and the Canvas2D bridge are wired up (M3/M4), so this
    # now tracks whether the embedded JS engine is compiled in. On-screen
    # presentation is still being brought up, so a booted game may not yet draw.
    def runtime_available?
      js_available?
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

  # Evaluate the MV engine scripts in order inside the embedded host. The host
  # globals (window/console/XHR/require/timers/…) are installed when the JS
  # context is created (mruby-mvjs/src/mvjs.cxx); each script's globals are
  # visible to the next through the shared persistent context. Missing optional
  # library files are skipped; the game's own scripts are expected to be present.
  def boot
    @clock = 0.0
    self.class.core_scripts.each do |script|
      path = "#{@game_dir}/#{script}"
      MV::JS.eval_file(path) if File.exist?(path)
    end
    # Our host has no DOM error UI, so route MV's fatal-error printer to the
    # console (stdout). MV's Graphics.printError draws into an "upper canvas"
    # that may not exist yet when an early boot error is caught, which otherwise
    # masks the real error with a secondary crash in Graphics._clearUpperCanvas.
    MV::JS.eval(
      "if (typeof Graphics !== 'undefined') { Graphics.printError = " \
      "function(n, m){ if (typeof console !== 'undefined' && console.error) " \
      "console.error('[MV] ' + n + ': ' + m); }; }"
    )

    # MV registers its entry point on window.onload (see the game's main.js);
    # in a browser the page-load event calls it. Fire it now that every script
    # is loaded, which runs SceneManager.run(Scene_Boot) and starts the game.
    MV::JS.eval("if (typeof window.onload === 'function') { window.onload(); }")
  end

  # Advance the game's timer/requestAnimationFrame queue by one host frame. Time
  # advances at the engine's nominal 60 fps so MV's frame timing stays sane.
  def pump_frame
    @clock = (@clock || 0.0) + 1000.0 / 60.0
    MV::JS.pump(@clock)
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
