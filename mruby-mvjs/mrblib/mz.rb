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
#      MZ's engine ships only with the paid editor and has no equivalent
#      open-source release, so running MZ needs a user-supplied MZ project
#      rather than a committed or fetched engine.
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
  # host draws through RGSS::Bitmap, not the DOM. Idempotent, so re-evaluating
  # is harmless.
  HOST_GLOBALS_JS =
    "(function(g){ " \
    "if (typeof g.HTMLVideoElement === 'undefined') " \
    "g.HTMLVideoElement = function(){}; " \
    "if (typeof g.HTMLImageElement === 'undefined') " \
    "g.HTMLImageElement = function(){}; })(globalThis);".freeze

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
      skip = ["js/main.js", "js/libs/vorbisdecoder.js"]
      CORE_SCRIPTS.reject { |s| skip.include?(s) }
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

  # Native entry point. The WebGL renderer (M6.3) is not built, so a full game
  # cannot boot; but the M6.2 host reuse can still drive the shared host through
  # the engine to the exact renderer boundary. Do that once to verify the host
  # reuse and surface where it stops, then report the pending backend cleanly.
  # The rest of the binary — and the other makers — are unaffected either way.
  def start
    boundary = boot_probe
    if boundary && !boundary.empty?
      $stderr.puts "[MZ] host reuse reached the renderer boundary: " \
                   "#{boundary.split("\n").first}"
    end
    warn_runtime_pending
  rescue StandardError => e
    $stderr.puts "[MZ] boot probe error: #{e.message}"
    warn_runtime_pending
  end

  # Per-frame entry point (Emscripten drives this directly, as for the other
  # makers). A no-op beyond the pending notice until the renderer lands: without
  # WebGL nothing can be presented, so there is no per-frame work to do.
  def main_loop
    warn_runtime_pending
  end

  private

  # M6.2 host reuse: drive the shared quickjs host through the real MZ engine as
  # far as it goes without a renderer, and return the exact boundary it stops
  # at. This is *not* a playable boot — MZ's PIXI v5 is WebGL-only and the
  # WebGL-subset backend (M6.3) is not built, so `SceneManager.run` reaches the
  # `Utils.canUseWebGL()` guard in `rmmz_managers.js` and throws. Running to
  # that precise wall — rather than guessing at it — is the M6.2 deliverable: it
  # proves the engine scripts, the extra host globals, the IO bridge and the
  # load order are all correct right up to the renderer.
  #
  # Returns the caught renderer-boundary error (a `Utils.canUseWebGL` throw when
  # the engine is present), or an empty string when the engine scripts are
  # absent (nothing to run) or it stops somewhere unexpected.
  #
  # There is no committable/fetchable MZ engine (© Gotcha Gotcha Games /
  # KADOKAWA — see ADR 0004 M6.2), so this path is verified locally against a
  # user-supplied MZ project rather than in CI; the pure logic it leans on
  # (`runnable_scripts`, `host_globals_js`) is covered by host specs.
  def boot_probe
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

    # SceneManager.run swallows a boot exception through catchException; replace
    # it so the WebGL wall it hits is captured instead of vanishing, then run.
    MV::JS.eval(
      "if (typeof SceneManager !== 'undefined') { SceneManager.__mzErr = null; " \
      "SceneManager.catchException = function(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); }; }"
    )
    MV::JS.eval(
      "(function(){ if (typeof SceneManager === 'undefined' || " \
      "typeof Scene_Boot === 'undefined') return; try { " \
      "SceneManager.run(Scene_Boot); } catch(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); } })();"
    )
    MV::JS.eval(
      "(function(){ return (typeof SceneManager !== 'undefined' && " \
      "SceneManager.__mzErr) ? SceneManager.__mzErr : ''; })();"
    )
  end

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[MZ] RPG Maker MZ support is under construction: the engine " \
                 "now loads on the shared host (M6.2), but MZ ships PIXI v5 " \
                 "(WebGL-only) and the WebGL-subset backend it needs (M6.3) is " \
                 "not built into this binary yet, so no frame can render. The " \
                 "engine/host/IO/input/audio layers are shared with MV; only " \
                 "the renderer is missing. See " \
                 "docs/adr/0004-javascript-maker-mv-quickjs.md (M6)."
  end
end
