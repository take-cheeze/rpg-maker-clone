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
#      lz-string). Unlike MV — whose corescript is an official MIT project
#      (rpgtkoolmv, redistributed by KADOKAWA) that `data/mv-sample` fetches —
#      MZ has no equivalent official open-source release, so `data/mz-sample`
#      commits only an authored minimal database and fetches the rmmz engine from
#      a community mirror at build time (`scripts/download-mz-corescript.bash`) —
#      a CI-only test fixture, downloaded the same way the proprietary RPG2k/XP
#      games are, never committed or redistributed.
#   2. It ships **PIXI v5, which is WebGL-only** — there is no Canvas2D renderer
#      to map onto the `Canvas2D -> Bitmap` bridge MV drives. Rendering therefore
#      needs a WebGL-subset backend on LVGL, which is the bulk of milestone M6
#      and is **not built yet**.
#
# This class carries the M6.1 foundation (project detection + canonical script
# load order) and the M6.2 host reuse: when pointed at an MZ game it now drives
# the shared quickjs host through the real `rmmz_*` engine as far as it goes
# without a renderer — loading every script, installing the extra host globals
# MZ needs, and running `SceneManager.run(Scene_Boot)` up to the point PIXI v5
# demands WebGL — then reports that precise boundary and the pending backend
# cleanly. Only the WebGL-subset renderer (M6.3) is still missing.
class MZ
  # RPG Maker MZ renders at 816x624 by default, same nominal canvas as MV.
  WIDTH = 816
  HEIGHT = 624

  # The files that unambiguously mark a directory as an RPG Maker MZ project:
  # the core engine script and the system database. MV uses `js/rpg_core.js`
  # instead, so the two never collide.
  REQUIRED_MARKERS = ["js/rmmz_core.js", "data/System.json"].freeze

  # The MZ engine scripts, in the order they load: the vendored libraries first
  # (PIXI v5, then pako for save compression, localforage for storage, Effekseer
  # for animations, and the Vorbis decoder), then the engine modules, then the
  # game's plugin list and entry point. Verified against the real engine's
  # `main.js` `scriptUrls` (the exact filenames — e.g. `vorbisdecoder.js`, not
  # `vorbis.js`). As on the MV side the runtime prefers the game's own
  # `index.html` when present and only falls back to this list.
  #
  # NB: MZ's boot entry differs from MV's. MV registers `window.onload`; MZ's
  # `main.js` is itself the loader — it injects the other scripts as `<script>`
  # elements and, once they load, initialises the Effekseer WASM runtime and
  # calls `SceneManager.run(Scene_Boot)`. So the host reuse (M6.2) cannot simply
  # eval `main.js`; it drives the load sequence itself (see #boot_probe and
  # `runnable_scripts`) and bypasses the Effekseer WASM init, which `main.js`
  # would otherwise gate the boot on — Effekseer only draws battle animations,
  # so skipping it does not block reaching a scene (see ADR 0004 M6.2).
  CORE_SCRIPTS = [
    "js/libs/pixi.js",
    "js/libs/pako.min.js",
    "js/libs/localforage.min.js",
    "js/libs/effekseer.min.js",
    "js/libs/vorbisdecoder.js",
    "js/rmmz_core.js",
    "js/rmmz_managers.js",
    "js/rmmz_objects.js",
    "js/rmmz_scenes.js",
    "js/rmmz_sprites.js",
    "js/rmmz_windows.js",
    "js/plugins.js",
    "js/main.js",
  ].freeze

  # The extra host globals MZ needs on top of MV's shims. `rmmz_managers.js`
  # references `HTMLVideoElement` and `HTMLImageElement` at module-load time
  # (its Graphics/Video setup) and the whole module fails to define if they are
  # undefined; MV's `rpg_*` never touch them, so the shared host does not
  # provide them. Empty constructors are enough to get past module load — the
  # host draws through RGSS::Bitmap, not the DOM.
  #
  # `indexedDB` is the one host global MZ's boot needs that MV's did not reach:
  # `SceneManager.checkBrowser` (run after `Utils.canUseWebGL`, which the WebGL
  # backend now passes) throws "does not support IndexedDB" without it, and
  # `localforage` — MZ's save storage — probes it. A truthy stub gets past the
  # guard; real save persistence rides the RGSS host, not IndexedDB, so the stub
  # never has to store anything for the boot to render. Idempotent, so
  # re-evaluating is harmless.
  HOST_GLOBALS_JS =
    "(function(g){ " \
    "if (typeof g.HTMLVideoElement === 'undefined') " \
    "g.HTMLVideoElement = function(){}; " \
    "if (typeof g.HTMLImageElement === 'undefined') " \
    "g.HTMLImageElement = function(){}; " \
    "if (typeof g.indexedDB === 'undefined') " \
    "g.indexedDB = { open: function(){ return { onsuccess: null, " \
    "onerror: null, onupgradeneeded: null, result: null }; }, " \
    "deleteDatabase: function(){ return {}; } }; })(globalThis);".freeze

  class << self
    # The canonical MZ script load order (see CORE_SCRIPTS).
    def core_scripts
      CORE_SCRIPTS
    end

    # The subset of CORE_SCRIPTS the host reuse (M6.2) actually evaluates to
    # drive the engine to a scene, in load order. Two entries are dropped from
    # the browser's full list:
    #
    #   * `js/main.js` — MZ's entry point is itself a dynamic
    #     `<script>`-injection loader; the host drives the load order directly
    #     (see #boot_probe) rather than eval the loader, just as the MV side
    #     bypasses the `<script>` tags `window.onload` would inject.
    #   * `js/libs/vorbisdecoder.js` — gated on `WebAssembly`, which the quickjs
    #     host does not provide, and used only to decode Ogg audio; evaluating
    #     it throws `ReferenceError: WebAssembly is not defined`, and audio
    #     rides the shared RGSS::Audio bridge instead, so skipping it does not
    #     block reaching a scene.
    def runnable_scripts
      CORE_SCRIPTS - ["js/main.js", "js/libs/vorbisdecoder.js"]
    end

    # The JS that installs MZ's extra host globals (see HOST_GLOBALS_JS).
    def host_globals_js
      HOST_GLOBALS_JS
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

    # True where the WebGL-subset backend PIXI v5 needs (milestone M6.3) is
    # compiled in — the surfaceless-EGL GLES2 context (MV::GL). There MZ boots to
    # Scene_Boot and presents frames on-screen (see #start / #main_loop); where
    # it is absent (Emscripten uses the browser's own WebGL; header-less builds)
    # MZ falls back to the boot probe that reports the pending state.
    def runtime_available?
      MV::GL.available?
    end
  end

  def initialize(args)
    @args = args
    @game_dir = GAME_DIR
  end

  attr_reader :game_dir

  # Native entry point. Boot the real MZ engine on the shared host through the
  # WebGL renderer and report how far it got. A `[MZ-BOOT]` marker on success
  # (the reached scene) is what `scripts/mz_boot_check.rb` asserts in CI; a boot
  # error is surfaced instead. Continuous play (input, per-frame present) is not
  # wired yet, so the pending notice still follows. The rest of the binary — and
  # the other makers — are unaffected either way.
  def start
    unless self.class.runtime_available?
      # No native WebGL backend (e.g. header-less builds): probe how far the
      # boot gets and report, as before — nothing can be presented.
      boundary = boot_probe
      if boundary && !boundary.empty?
        $stderr.puts "[MZ] boot stopped at: #{boundary.split("\n").first}"
      elsif @boot_scene && !@boot_scene.empty?
        $stderr.puts "[MZ-BOOT] booted to #{@boot_scene} through the WebGL " \
                     "renderer"
      end
      warn_runtime_pending
      return
    end

    boot
    # Only enter the frame loop if the boot actually reached a scene; if WebGL
    # could not be made current (e.g. running under an X server, where Mesa
    # rejects the bind — see mvgl.cxx), there is nothing to present, so report
    # the boundary instead of spinning on a dead SceneManager.
    if @boot_scene.nil? || @boot_scene.empty?
      warn_runtime_pending
      return
    end
    loop { main_loop }
  rescue RGSS::Timeout
    # The engine raises this to unwind the run loop cleanly (e.g. --timeout_ms).
  rescue StandardError => e
    $stderr.puts "[MZ] boot error: #{e.message}"
    warn_runtime_pending
  end

  # One iteration of the host loop (Emscripten drives this directly): advance MZ
  # by a frame, present the WebGL frame on-screen, then let RGSS repaint. A no-op
  # beyond the pending notice where WebGL is absent.
  def main_loop
    unless self.class.runtime_available?
      warn_runtime_pending
      return
    end
    # Under Emscripten main_loop is called without #start; boot lazily once.
    boot unless @booted
    return if @boot_scene.nil? || @boot_scene.empty?

    sync_input # push RGSS input into MZ's Input before the scene updates
    sync_touch # push RGSS mouse into MZ's TouchInput before the scene update
    # Advance one MZ frame (SceneManager.update renders the scene through PIXI
    # into the WebGL canvas), then blit that frame on-screen. Guard the update so
    # a per-frame throw is logged, not fatal — one bad frame never aborts the
    # loop, as in a browser.
    MV::JS.eval(
      "(function(){ if (typeof SceneManager !== 'undefined') { try { " \
      "SceneManager.update(1); } catch(e){ if (typeof console !== " \
      "'undefined' && console.error) console.error('[MZ] frame: ' + " \
      "((e && (e.stack || e.message)) || e)); } } })();"
    )
    present
    RGSS::Input.update
    RGSS::Graphics.update
  end

  private

  # Boot the engine once: run it to Scene_Boot (via #boot_probe), report the
  # `[MZ-BOOT]` marker (or the boundary if it stopped early), and create the
  # on-screen surface frames are presented onto. Sets @booted so the lazy boot
  # in #main_loop runs only once.
  def boot
    @booted = true
    boundary = boot_probe
    if boundary && !boundary.empty?
      $stderr.puts "[MZ] boot stopped at: #{boundary.split("\n").first}"
    elsif @boot_scene && !@boot_scene.empty?
      $stderr.puts "[MZ-BOOT] booted to #{@boot_scene} through the WebGL renderer"
    end
    create_screen
  end

  # Push the engine's held keys (RGSS::Input) into MZ's `Input._currentState`
  # before the scene updates, so SceneManager.update sees them. rmmz's Input has
  # the same virtual-button names and `_currentState` shape as rmmv, so the key
  # map and injection are shared with MV (MV.pressed_buttons reads only
  # RGSS::Input). Mirrors MV#sync_input.
  def sync_input
    assigns = MV.pressed_buttons.map { |b| "c['#{b}']=true;" }.join
    MV::JS.eval(
      "(function(){ if (typeof Input === 'undefined' || !Input._currentState) " \
      "return; var c = Input._currentState; for (var k in c) c[k] = false; " \
      "#{assigns} })();"
    )
  rescue StandardError => e
    $stderr.puts "[MZ] input sync error: #{e.message}"
  end

  # Push a pointer sample (mouse x/y + left button) into MZ's TouchInput before
  # the scene updates, so menu/map clicks work. rmmz's TouchInput takes the same
  # `_newState` edges as rmmv, so the bridge JS is shared with MV. Mirrors
  # MV#sync_touch.
  def sync_touch
    MV::JS.eval(
      MV.touch_bridge_js(
        RGSS::Input.mouse_x, RGSS::Input.mouse_y, RGSS::Input.mouse_pressed?
      )
    )
  rescue StandardError => e
    $stderr.puts "[MZ] touch sync error: #{e.message}"
  end

  # The on-screen surface MZ's WebGL frame is presented onto: one full-screen
  # sprite whose bitmap #present overwrites each frame (mirrors MV#create_screen).
  # Held in instance variables so neither is garbage-collected while running.
  def create_screen
    @screen_bitmap = RGSS::Bitmap.new(WIDTH, HEIGHT)
    @screen_sprite = RGSS::Sprite.new
    @screen_sprite.bitmap = @screen_bitmap
    @screen_sprite.z = 0
  end

  # Copy MZ's rendered WebGL frame onto the on-screen bitmap. PIXI renders into
  # the WebGL canvas' FBO during SceneManager.update; MV::JS.present_gl reads that
  # FBO back and blits it into the sprite's bitmap (marking it dirty) so the next
  # Graphics.update draws it.
  def present
    return unless @screen_bitmap
    handle = mz_gl_handle
    unless @present_logged
      @present_logged = true
      if handle && handle > 0
        $stderr.puts "[MZ] presenting frames on-screen (webgl handle #{handle})"
      else
        $stderr.puts "[MZ] present: no WebGL context handle resolved; " \
                     "frames not shown"
      end
    end
    MV::JS.present_gl(@screen_bitmap, handle) if handle && handle > 0
  end

  # Resolve the integer handle of MZ's main WebGL context (the id stored as
  # `.__gl` on the WebGLRenderingContext the wrapper returns). PIXI v5 exposes it
  # as `Graphics._app.renderer.gl`; fall back to the canvas' cached context.
  # Cached once non-zero (the renderer is created once, at boot).
  def mz_gl_handle
    return @mz_gl_handle if @mz_gl_handle && @mz_gl_handle > 0
    @mz_gl_handle = MV::JS.eval(<<~'JS').to_i
      (function () {
        try {
          if (typeof Graphics === 'undefined') return 0;
          var gl = (Graphics._app && Graphics._app.renderer &&
                    Graphics._app.renderer.gl) || null;
          if (!gl && Graphics._canvas && Graphics._canvas.getContext) {
            gl = Graphics._canvas.getContext('webgl');
          }
          return (gl && gl.__gl) ? gl.__gl : 0;
        } catch (e) { return 0; }
      })();
    JS
  end

  # Drive the shared quickjs host through the real MZ engine and boot it. With
  # the WebGL backend built (M6.3), `SceneManager.run(Scene_Boot)` gets past the
  # `Utils.canUseWebGL()` guard that used to be the wall (M6.2): `Graphics`
  # creates the PIXI renderer on the native surfaceless-EGL GLES2 context and
  # the scene runs. A handful of frames are then driven so `Scene_Boot` actually
  # creates and renders — the M6.3c "renders Scene_Boot" goal — rather than only
  # constructing the SceneManager.
  #
  # Records the reached scene name in `@boot_scene`, and returns the caught boot
  # error (empty string on success, or when the engine scripts are absent so
  # there is nothing to run). The engine is fetched into `data/mz-sample` by
  # `scripts/download-mz-corescript.bash`, so — unlike under M6.2 — this now runs
  # in CI (`scripts/mz_boot_check.rb`), not only against a user-supplied project.
  def boot_probe
    @boot_scene = ""
    return "" unless self.class.project?(@game_dir)

    # MZ's own scripts request data/assets with game-relative paths; root them
    # at the game dir since the process is not chdir'd into it (as MV does).
    MV::JS.base_dir = @game_dir
    MV::JS.eval(self.class.host_globals_js)

    self.class.runnable_scripts.each do |script|
      path = "#{@game_dir}/#{script}"
      next unless File.exist?(path)
      begin
        MV::JS.eval_file(path)
      rescue StandardError => e
        # As in a browser, a script that throws while executing is logged and
        # the next one still runs — one bad script never aborts the page.
        $stderr.puts "[MZ] error loading #{script}: #{e.message}"
      end
    end

    # Replace catchException so a boot error is captured (not swallowed), run the
    # boot, then drive a few frames so Scene_Boot creates and renders through the
    # WebGL renderer rather than only instantiating the SceneManager.
    MV::JS.eval(
      "(function(){ if (typeof SceneManager === 'undefined' || " \
      "typeof Scene_Boot === 'undefined') return; " \
      "SceneManager.__mzErr = null; " \
      "SceneManager.catchException = function(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); }; " \
      "try { SceneManager.run(Scene_Boot); " \
      "for (var i = 0; i < 60 && !SceneManager.__mzErr; i++) { " \
      "try { SceneManager.update(1); } catch(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); break; } } " \
      "} catch(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); } })();"
    )
    @boot_scene = MV::JS.eval(
      "(function(){ return (typeof SceneManager !== 'undefined' && " \
      "SceneManager._scene && SceneManager._scene.constructor) ? " \
      "SceneManager._scene.constructor.name : ''; })();"
    )
    MV::JS.eval(
      "(function(){ return (typeof SceneManager !== 'undefined' && " \
      "SceneManager.__mzErr) ? SceneManager.__mzErr : ''; })();"
    )
  end

  attr_reader :boot_scene

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[MZ] RPG Maker MZ support is under construction: where the " \
                 "WebGL backend is available the engine boots to Scene_Boot, " \
                 "presents frames on-screen and takes input (M6.3), but this " \
                 "build/run has no usable WebGL context (or the boot did not " \
                 "reach a scene), so there is nothing to present. The " \
                 "engine/host/IO/input/audio layers are shared with MV. See " \
                 "docs/adr/0004-javascript-maker-mv-quickjs.md (M6)."
  end
end
