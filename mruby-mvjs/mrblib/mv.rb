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
    "js/libs/iphone-inline-video.browser.js",
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

    # Map the engine's input keys (RGSS::Input, fed by the SDL/terminal
    # backends) onto MV's virtual buttons (the names in `Input.keyMapper`).
    # MV has no separate "cancel"/"menu": Escape/X serve both, so B maps to
    # 'escape'. Built at call time (not as a constant) so it does not depend on
    # RGSS being loaded before this file. See `MV#sync_input`.
    def input_map
      {
        RGSS::Input::UP => "up",
        RGSS::Input::DOWN => "down",
        RGSS::Input::LEFT => "left",
        RGSS::Input::RIGHT => "right",
        RGSS::Input::C => "ok",       # confirm (Z/Enter)
        RGSS::Input::B => "escape",   # cancel/menu (X/Esc)
        RGSS::Input::A => "shift",    # dash
        RGSS::Input::L => "pageup",
        RGSS::Input::R => "pagedown",
        RGSS::Input::CTRL => "control",
      }
    end

    # The MV virtual buttons currently held, derived from RGSS::Input. Split out
    # from the JS injection so the key mapping can be unit-tested without a live
    # MV engine.
    def pressed_buttons
      input_map.select { |key, _| RGSS::Input.press?(key) }.values
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

    sync_input # M5: push RGSS input into MV's Input before the scene updates
    pump_frame # M3: run the rAF/timer queue for one frame
    log_scene_transition # trace boot progress (Scene_Boot -> Scene_Title -> ...)
    present # M4: copy the MV canvas onto the on-screen sprite's bitmap
    maybe_screenshot # capture the rendered frame once, if requested (CI)
    RGSS::Input.update
    RGSS::Graphics.update
  end

  private

  # Bridge the engine's input to MV. MV reads keyboard state from
  # `Input._currentState`, which its browser build fills from DOM key events we
  # don't deliver; instead, each frame we set it directly from RGSS::Input (fed
  # by the SDL/terminal backends). MV's own `Input.update` — which it calls
  # during the scene update in `pump_frame` — turns this into the
  # triggered/pressed/repeat state the scenes query, so navigation, confirm and
  # cancel work. Runs before `pump_frame` so the state is in place when MV
  # reads it. No-op until the engine (and thus `Input`) has loaded.
  def sync_input
    buttons = self.class.pressed_buttons
    assigns = buttons.map { |b| "c['#{b}']=true;" }.join
    MV::JS.eval(
      "(function(){ if (typeof Input === 'undefined' || !Input._currentState) " \
      "return; var c = Input._currentState; for (var k in c) c[k] = false; " \
      "#{assigns} })();"
    )
  rescue StandardError => e
    $stderr.puts "[MV] input sync error: #{e.message}"
  end

  # If a screenshot path was requested (`--mv_screenshot`), write the rendered
  # MV frame to it once, a couple of seconds in — enough for the boot to reach
  # the title and its images to load and draw. Used to capture the visual output
  # in CI; a no-op during normal play (no path configured).
  def maybe_screenshot
    return if @shot_taken

    # MV_SCREENSHOT is set by the native launcher (main.cxx); `defined?` isn't
    # usable here (mruby treats it as a method call), so read it directly and
    # treat an unset constant as "no screenshot".
    path = begin
      MV_SCREENSHOT
    rescue StandardError
      ""
    end
    return if path.nil? || path.empty?

    @frames = (@frames || 0) + 1
    return if @frames < 120

    @shot_taken = true
    ok = MV::JS.screenshot(path)
    $stderr.puts "[MV] screenshot #{ok ? "saved" : "failed"}: #{path}"
  rescue StandardError => e
    $stderr.puts "[MV] screenshot error: #{e.message}"
  end

  # Log the running scene's class name whenever it changes, so the boot's
  # progress through the scene graph (Scene_Boot -> Scene_Title -> ...) is
  # visible — a scene-level heartbeat that also confirms the game reached the
  # title rather than silently looping in Scene_Boot. Scene changes are rare, so
  # this stays quiet during normal play.
  def log_scene_transition
    name = MV::JS.eval(
      "(typeof SceneManager !== 'undefined' && SceneManager._scene) ? " \
      "SceneManager._scene.constructor.name : null"
    )
    return if name.nil? || name == @last_scene

    @last_scene = name
    $stderr.puts "[MV] scene: #{name}"
  rescue StandardError
    nil
  end

  # Evaluate the MV engine scripts in order inside the embedded host. The host
  # globals (window/console/XHR/require/timers/…) are installed when the JS
  # context is created (mruby-mvjs/src/mvjs.cxx); each script's globals are
  # visible to the next through the shared persistent context. Missing optional
  # library files are skipped; the game's own scripts are expected to be present.
  def boot
    @clock = 0.0
    # MV's own scripts request data/assets with game-relative paths (e.g.
    # `data/System.json`, `img/system/Window.png`); root them at the game dir
    # since the process is not chdir'd into it.
    MV::JS.base_dir = @game_dir
    create_screen
    boot_scripts.each do |script|
      path = "#{@game_dir}/#{script}"
      next unless File.exist?(path)
      begin
        MV::JS.eval_file(path)
      rescue StandardError => e
        # In a browser, a script that throws while executing is reported to the
        # console and the *next* <script> still runs — one bad script never
        # aborts the page. Mirror that: log and continue, so a non-critical
        # library (e.g. iphone-inline-video's iOS-only inline-video shim, which
        # throws under our host) can't take down the whole boot.
        $stderr.puts "[MV] error loading #{script}: #{e.message}"
      end
    end
    # iphone-inline-video exposes makeVideoPlayableInline, which MV calls from
    # Graphics._createVideo. If that library was absent or threw before defining
    # it, install a no-op so video creation doesn't later crash — we have no
    # inline-video workaround to apply on this host anyway.
    MV::JS.eval(
      "if (typeof makeVideoPlayableInline === 'undefined') { " \
      "globalThis.makeVideoPlayableInline = function(){}; }"
    )
    # FPSMeter is a debug FPS-overlay library MV bundles and instantiates in
    # Graphics._createFPSMeter; it throws on our host (it expects a real DOM to
    # attach to), which aborts Graphics.initialize before the run loop starts.
    # Replace it with a no-op exposing the methods MV drives it with each frame
    # (tick/tickStart/show/hide/...); we don't draw an FPS overlay anyway.
    MV::JS.eval(
      "(function(g){ function FM(){} " \
      "['tick','tickStart','show','hide','showFps','showDuration','set'," \
      "'destroy'].forEach(function(m){ FM.prototype[m] = " \
      "function(){ return this; }; }); g.FPSMeter = FM; })(globalThis);"
    )
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
    # Guard it like the browser does — a throw here is logged, not fatal — so
    # the run loop still starts and later frames can surface the real problem.
    begin
      MV::JS.eval("if (typeof window.onload === 'function') { window.onload(); }")
    rescue StandardError => e
      $stderr.puts "[MV] error in window.onload: #{e.message}"
    end
  end

  # The scripts to evaluate, in order. Prefer the game's own index.html — the
  # authoritative load list, which varies by MV version and bundled libraries
  # (e.g. iphone-inline-video.browser.js) — and fall back to CORE_SCRIPTS.
  def boot_scripts
    index = "#{@game_dir}/index.html"
    if File.exist?(index)
      html = File.open(index, "r") { |f| f.read }
      srcs = html.scan(/<script[^>]*\bsrc\s*=\s*["']([^"']+)["']/i).flatten
      return srcs unless srcs.empty?
    end
    self.class.core_scripts
  rescue StandardError
    self.class.core_scripts
  end

  # Create the on-screen surface the MV canvas is presented onto: a single
  # full-screen sprite whose bitmap we overwrite each frame. Held in instance
  # variables so neither is garbage-collected while the game runs.
  def create_screen
    @screen_bitmap = RGSS::Bitmap.new(WIDTH, HEIGHT)
    @screen_sprite = RGSS::Sprite.new
    @screen_sprite.bitmap = @screen_bitmap
    @screen_sprite.z = 0
  end

  # Copy MV's current canvas frame onto the on-screen bitmap. MV renders through
  # PIXI into its canvas during pump; this blits that canvas into the sprite's
  # bitmap (marking it dirty) so Graphics.update draws it.
  def present
    MV::JS.present(@screen_bitmap) if @screen_bitmap
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
