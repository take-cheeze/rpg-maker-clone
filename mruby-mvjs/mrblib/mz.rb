# RPG Maker MZ support (milestone M6).
#
# MZ is the JavaScript maker family's newer member: like MV it is a *JavaScript*
# application with a `data/*.json` database, and it runs on the same embedded
# quickjs-ng host, host-global shims and IO/input bridges that MV already uses
# (see mruby-mvjs and docs/adr/0004-javascript-maker-mv-quickjs.md). Two things
# set it apart:
#
#   1. Its engine scripts are `js/rmmz_*.js` (not MV's `js/rpg_*.js`), loaded in
#      a slightly different order (pako/localforage/effekseer instead of MV's
#      lz-string). Unlike MV — whose corescript is an official MIT project
#      (rpgtkoolmv, redistributed by KADOKAWA) that `data/mv-sample` fetches —
#      MZ has no equivalent official open-source release, so `data/mz-sample`
#      commits only an authored database and art and fetches the rmmz engine from
#      a community mirror at build time (`scripts/download-mz-corescript.bash`) —
#      a CI-only test fixture, downloaded the same way the proprietary RPG2k/XP
#      games are, never committed or redistributed.
#   2. It ships **PIXI v5, which is WebGL-only** — there is no Canvas2D renderer
#      to map onto the `Canvas2D -> Bitmap` bridge MV drives, so rendering goes
#      through the native surfaceless-EGL GLES2 backend instead (`MV::GL` /
#      `mruby-mvjs/src/mvwebgl.cxx`, milestone M6.3).
#
# With that backend built, this class boots a real MZ game and plays it: it
# loads the `rmmz_*` scripts on the shared host, installs the extra globals MZ
# needs, runs `SceneManager.run(Scene_Boot)` and then advances the game by
# pumping the host once per frame — MZ drives itself from PIXI's ticker, so a
# pumped frame is what updates the scene, renders it into the WebGL canvas and
# runs the asynchronous loads the boot waits on. The rendered frame is read back
# out of the FBO and presented on an RGSS sprite, and RGSS input is fed into
# rmmz's `Input`/`TouchInput`, so the title screen and the map are on-screen and
# walkable. Where the backend is absent (Emscripten uses the browser's own
# WebGL; header-less builds) it degrades to reporting how far the boot got.
class MZ
  # RPG Maker MZ renders at 816x624 by default, same nominal canvas as MV.
  WIDTH = 816
  HEIGHT = 624

  # How many frames #boot_probe pumps while waiting for `Scene_Boot` to finish
  # loading and hand over to the title. Generous: the boot polls the database,
  # the system images, the fonts and the storage layer, each of which resolves a
  # frame or more after it is requested, and a headless run is slower than 60Hz.
  BOOT_PROBE_FRAMES = 600

  # Frames to wait for `Scene_Map` after requesting New Game before reporting a
  # failure (see #maybe_move_test). The title's command window closing, its fade
  # out and the map's own fade in all have to play out first.
  MAP_PROBE_FRAMES = 300

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
  # provide them. An empty constructor is enough for the video one — the host
  # draws through RGSS::Bitmap, not the DOM.
  #
  # `HTMLImageElement` must be the host's own `Image` constructor, though, not a
  # fresh empty one: PIXI v5 decides how to wrap a texture source with
  # `source instanceof HTMLImageElement` (`ImageResource`), and when that is
  # false it builds a *new* `Image` and assigns the object it was handed to its
  # `src`. Every bitmap MZ loads would then be a broken texture. Aliasing the
  # two makes `Bitmap._createBaseTexture(this._image)` take PIXI's image path,
  # which uploads through the wrapper's `texImage2D` canvas/image handle.
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
    "g.HTMLImageElement = (typeof g.Image === 'function') ? g.Image : " \
    "function(){}; " \
    "if (typeof g.indexedDB === 'undefined') " \
    "g.indexedDB = { open: function(){ return { onsuccess: null, " \
    "onerror: null, onupgradeneeded: null, result: null }; }, " \
    "deleteDatabase: function(){ return {}; } }; })(globalThis);".freeze

  # What MZ needs on top of MV's audio bridge (`MV::AUDIO_BRIDGE_JS`, which
  # replaces the high-level play/stop/fade methods so ops queue for RGSS::Audio).
  #
  # MV's bridge deliberately leaves `loadStaticSe`/`createBuffer` alone, because
  # on the MV side nothing reaches them once the play methods are replaced. MZ
  # does reach them: `Scene_Boot.start` calls
  # `SoundManager.preloadImportantSounds()`, which loads the system SEs eagerly
  # through `AudioManager.loadStaticSe` -> `createBuffer` -> `new WebAudio`. And
  # MZ's `WebAudio` fetches with **`fetch`** (MV used XMLHttpRequest), which this
  # host does not provide — so the moment a game names a system sound, the boot
  # dies in `Scene_Boot.start` with "ReferenceError: fetch is not defined".
  #
  # Preloading is only an optimisation when playback is bridged, so both are
  # neutralised: `loadStaticSe` becomes a no-op and `createBuffer` returns an
  # inert object rather than constructing a WebAudio. Playback still goes through
  # the bridged `playSe`.
  AUDIO_BRIDGE_EXTRA_JS =
    "(function(g){ if (typeof AudioManager === 'undefined') return; " \
    "AudioManager.loadStaticSe = function(){}; " \
    "AudioManager.isStaticSe = function(){ return false; }; " \
    "AudioManager.createBuffer = function(){ return { " \
    "play: function(){}, stop: function(){}, fadeIn: function(){}, " \
    "fadeOut: function(){}, isPlaying: function(){ return false; }, " \
    "isReady: function(){ return true; }, isError: function(){ return false; }, " \
    "addLoadListener: function(){}, volume: 0, pitch: 0, pan: 0, seek: 0 }; }; " \
    "})(globalThis);".freeze

  class << self
    # The canonical MZ script load order (see CORE_SCRIPTS).
    def core_scripts
      CORE_SCRIPTS
    end

    # The JS that routes MZ's audio through RGSS::Audio: MV's shared bridge plus
    # the MZ-only overrides above (see AUDIO_BRIDGE_EXTRA_JS).
    def audio_bridge_js
      "#{MV::AUDIO_BRIDGE_JS}\n#{AUDIO_BRIDGE_EXTRA_JS}"
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
    # the title, plays and presents frames on-screen (see #start / #main_loop);
    # where it is absent (Emscripten uses the browser's own WebGL; header-less
    # builds) MZ falls back to the boot probe that reports the pending state.
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
  # WebGL renderer, report how far it got and then run the game. A `[MZ-BOOT]`
  # marker naming the reached scene is what `scripts/mz_boot_check.bash` asserts
  # in CI; a boot error is surfaced instead. The rest of the binary — and the
  # other makers — are unaffected either way.
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
    pump_frame # advance MZ one frame: its own rAF loop updates and renders
    pump_audio # drain the ops rmmz's AudioManager queued into RGSS::Audio
    @scene = scene_name # read once a frame; the probes below all consult it
    log_scene_transition # trace progress (Scene_Boot -> Scene_Title -> Map)
    maybe_new_game # CI: auto-advance past the title to the first map
    maybe_move_test # CI: hold a direction on the map and log that the player moved
    maybe_audio_test # CI: play an SE through the bridge and log it dispatched
    present
    maybe_screenshot # capture the presented frame once, if requested (CI)
    RGSS::Input.update
    RGSS::Graphics.update
  end

  private

  # Advance the JavaScript host by one frame. This is the whole of MZ's update:
  # `SceneManager.run` hands the loop to `Graphics.startGameLoop`, which starts
  # PIXI's ticker, and the ticker re-arms itself through `requestAnimationFrame`.
  # Pumping the host therefore fires the ticker (which calls `SceneManager.update`
  # through `Graphics._onTick` *and* renders the scene into the WebGL canvas),
  # runs due timers and drains the promise microtasks the engine's asynchronous
  # loads (localforage saves/config, image decode callbacks) wait on.
  #
  # Calling `SceneManager.update` from Ruby instead — as this loop used to — runs
  # the scene without ever rendering it (`Graphics._onTick` is what calls
  # `_app.render()`) and leaves those callbacks queued forever, which is why the
  # boot could not get past `Scene_Boot`: it polls `ImageManager`/`ConfigManager`
  # readiness that only a pumped frame can deliver. Shared cadence with MV
  # (MV#pump_frame): a fixed 1/60s step, so the JS clock matches the engine's.
  def pump_frame
    @clock = (@clock || 0.0) + 1000.0 / 60.0
    MV::JS.pump(@clock)
  rescue StandardError => e
    # One bad frame is logged, not fatal — as in a browser, where an exception
    # in a rAF callback does not stop the page. A failure that repeats every
    # frame is reported once rather than per frame, so the log stays readable.
    return if e.message == @last_frame_error
    @last_frame_error = e.message
    $stderr.puts "[MZ] frame error: #{e.message}"
  end

  # Boot the engine once: run it up to the game's first scene (via #boot_probe),
  # report the `[MZ-BOOT]` marker (or the boundary if it stopped early), and
  # create the on-screen surface frames are presented onto. Sets @booted so the
  # lazy boot in #main_loop runs only once.
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

  # Drain the audio ops rmmz queued this frame and play them through
  # RGSS::Audio. rmmz's `AudioManager` exposes the same high-level surface MV's
  # bridge overrides (playBgm/playSe/fadeOutBgm/stopAll/...), so MZ installs
  # `MV::AUDIO_BRIDGE_JS` verbatim and drains the identical op queue — the whole
  # reason MZ had no sound was that nobody installed it, not that MZ differed.
  # Without the bridge, audio goes to the silent Web Audio stub instead.
  #
  # The first dispatched op is logged as `[MZ-AUDIO]` so a headless run can prove
  # the path end to end (an asset that does not resolve plays nothing silently).
  def pump_audio
    data = MV::JS.eval(
      "(typeof __mv_drainAudio === 'function') ? __mv_drainAudio() : ''"
    )
    return unless data.is_a?(String) && !data.empty?

    data.split("\n").each do |line|
      next if line.empty?
      call = MV.parse_audio_op(line)
      next unless call

      unless @audio_logged
        @audio_logged = true
        $stderr.puts "[MZ-AUDIO] op=#{call[0]} asset=#{call[1]}"
      end
      MV.apply_audio_op(call)
    end
  rescue StandardError => e
    $stderr.puts "[MZ] audio error: #{e.message}"
  end

  # The running scene's class name, or "" before the first scene is created.
  def scene_name
    MV::JS.eval(
      "(function(){ return (typeof SceneManager !== 'undefined' && " \
      "SceneManager._scene && SceneManager._scene.constructor) ? " \
      "SceneManager._scene.constructor.name : ''; })();"
    )
  rescue StandardError
    ""
  end

  # Has the boot handed over from the loading scene to the game's first real
  # scene? True once a scene exists and it is no longer `Scene_Boot`.
  def boot_finished?
    name = scene_name
    !name.empty? && name != "Scene_Boot"
  end

  # The scene name sampled by the current frame (see #main_loop), so the probes
  # below share one lookup instead of each evaluating JS again.
  def current_scene
    @scene || ""
  end

  # Log each scene change once, so a headless run shows how far the game got
  # (Scene_Boot -> Scene_Title -> Scene_Map). Mirrors MV#log_scene_transition.
  def log_scene_transition
    name = current_scene
    return if name.empty? || name == @last_scene
    @last_scene = name
    $stderr.puts "[MZ-SCENE] #{name}"
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

  # Whether --mz_new_game was requested (a launcher constant set by main.cxx).
  # Read defensively: the constant is absent under the mruby test harness, and
  # mruby treats `defined?` as a method call, so it is read through a rescue.
  def new_game_requested?
    (begin
      MZ_NEW_GAME
    rescue StandardError
      false
    end) == true
  end

  # Whether --mz_move_test was requested (a launcher constant set by main.cxx).
  # Implies New Game, since the probe needs the map.
  def move_test_requested?
    (begin
      MZ_MOVE_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_new_game is set (CI) — or the movement probe is requested, which
  # needs the map first — pick "New Game" once the title is up, so the game
  # advances to its start map without any input and a headless run exercises the
  # in-game render path instead of only the title. One-shot; a no-op during
  # normal play (flags unset). Mirrors MV#maybe_new_game.
  def maybe_new_game
    return if @new_game_done
    return unless new_game_requested? || move_test_requested? ||
                  audio_test_requested?
    return unless current_scene == "Scene_Title"

    @new_game_done = true
    MV::JS.eval(
      "(function(){ if (SceneManager._scene && " \
      "SceneManager._scene.commandNewGame) " \
      "SceneManager._scene.commandNewGame(); })();"
    )
    $stderr.puts "[MZ] auto New Game"
  rescue StandardError => e
    $stderr.puts "[MZ] new game error: #{e.message}"
  end

  # The player's current map tile as "x,y", or "" before the game is up.
  def player_tile
    MV::JS.eval(
      "(function(){ return (typeof $gamePlayer !== 'undefined' && $gamePlayer) " \
      "? ($gamePlayer.x + ',' + $gamePlayer.y) : ''; })();"
    )
  rescue StandardError
    ""
  end

  # When --mz_move_test is set (CI), once on the map hold a direction — cycling
  # so some open direction is found — through RGSS::Input for MV::MOVE_PROBE_FRAMES
  # frames, then log the player's start/end tile and whether it ever moved. This
  # drives the whole chain (RGSS::Input -> #sync_input -> rmmz Input -> Scene_Map
  # -> Game_Player -> Game_Map passability -> position), so a headless run proves
  # input actually walks the player rather than only that a map renders. The keys
  # are read by the next frame's #sync_input. One-shot; a no-op during normal
  # play. Mirrors MV#maybe_move_test, and reuses MV's probe cadence and direction
  # cycle so both runtimes are exercised the same way.
  def maybe_move_test
    return if @move_test_done
    return unless move_test_requested?

    unless current_scene == "Scene_Map"
      # Still on the way there (title fade, map load). Give up with a failure
      # line if the map never arrives, rather than probing forever.
      @map_wait = (@map_wait || 0) + 1
      return if @map_wait < MAP_PROBE_FRAMES

      @move_test_done = true
      $stderr.puts "[MZ-MOVE] never reached the map (scene #{current_scene})"
      return
    end

    @move_frame ||= 0
    if @move_frame.zero?
      @move_start = player_tile
      $stderr.puts "[MZ-MAP] reached the map at #{@move_start}"
      $stderr.puts "[MZ-MOVE] start #{@move_start}"
    end
    cur = player_tile
    @move_seen = true if !cur.empty? && cur != @move_start

    dirs = [RGSS::Input::UP, RGSS::Input::DOWN, RGSS::Input::LEFT,
            RGSS::Input::RIGHT]
    dirs.each { |k| RGSS::Input.release(k) }
    @move_frame += 1
    if @move_frame < MV::MOVE_PROBE_FRAMES
      RGSS::Input.press(MV.move_probe_dir(@move_frame))
      return
    end

    @move_test_done = true
    $stderr.puts "[MZ-MOVE] end #{player_tile} moved=#{@move_seen ? true : false}"
  rescue StandardError => e
    $stderr.puts "[MZ] move test error: #{e.message}"
  end

  # Whether --mz_audio_test was requested (a launcher constant set by main.cxx).
  # Implies New Game, since the probe plays its sound once on the map.
  def audio_test_requested?
    (begin
      MZ_AUDIO_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_audio_test is set (CI), play one SE through rmmz's own
  # AudioManager once the map is up, so a headless run proves the whole audio
  # chain — AudioManager -> the bridge's op queue -> #pump_audio -> RGSS::Audio
  # -> the SDL mixer — rather than only that the bridge is installed. The sample
  # ships an authored `audio/se/Beep.wav` for exactly this. One-shot; a no-op
  # during normal play. Mirrors MV#maybe_audio_test.
  def maybe_audio_test
    return if @audio_test_done
    return unless audio_test_requested?
    return unless current_scene == "Scene_Map"

    @audio_test_done = true
    MV::JS.eval(
      "(function(){ if (typeof AudioManager !== 'undefined') " \
      "AudioManager.playSe({ name: 'Beep', volume: 90, pitch: 100, pan: 0 }); " \
      "})();"
    )
    $stderr.puts "[MZ] auto audio test: played SE Beep"
  rescue StandardError => e
    $stderr.puts "[MZ] audio test error: #{e.message}"
  end

  # If a screenshot path was requested (`--mz_screenshot`), write the presented
  # WebGL frame to it once, a couple of seconds in — enough for the boot to
  # reach a scene and its images to load and draw. Used to capture the visual
  # output in CI; a no-op during normal play (no path configured).
  def maybe_screenshot
    return if @shot_taken

    path = begin
      MZ_SCREENSHOT
    rescue StandardError
      ""
    end
    return if path.nil? || path.empty?

    @frames = (@frames || 0) + 1
    return if @frames < 120

    @shot_taken = true
    handle = mz_gl_handle
    ok = handle && handle > 0 && MV::JS.screenshot_gl(path, handle)
    $stderr.puts "[MZ] screenshot #{ok ? "saved" : "failed"}: #{path}"
  rescue StandardError => e
    $stderr.puts "[MZ] screenshot error: #{e.message}"
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
  # the scene runs. Frames are then pumped until `Scene_Boot` finishes loading
  # and hands over to `Scene_Title`, so the reported boot result is the game's
  # first real scene rather than the loading screen.
  #
  # Records the reached scene name in `@boot_scene`, and returns the caught boot
  # error (empty string on success, or when the engine scripts are absent so
  # there is nothing to run). The engine is fetched into `data/mz-sample` by
  # `scripts/download-mz-corescript.bash`, so — unlike under M6.2 — this now runs
  # in CI (`scripts/mz_boot_check.bash`), not only against a user-supplied
  # project.
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

    # Route rmmz's AudioManager through RGSS::Audio (see #pump_audio). Installed
    # after the engine scripts define AudioManager and before the boot runs, so
    # even the title BGM a game starts with is queued rather than lost to the
    # silent Web Audio stub.
    MV::JS.eval(self.class.audio_bridge_js)

    # Replace catchException so a boot error is captured (not swallowed) and run
    # the boot. `SceneManager.run` starts PIXI's ticker and returns; the scene is
    # then driven by pumping the host, one frame per pump (see #pump_frame).
    MV::JS.eval(
      "(function(){ if (typeof SceneManager === 'undefined' || " \
      "typeof Scene_Boot === 'undefined') return; " \
      "SceneManager.__mzErr = null; " \
      "SceneManager.catchException = function(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); }; " \
      "try { SceneManager.run(Scene_Boot); } catch(e){ SceneManager.__mzErr = " \
      "(e && (e.stack || e.message)) || String(e); } })();"
    )

    # Drive frames until the boot scene hands over to the next one (normally
    # Scene_Title). Scene_Boot is a *loading* scene: it polls its database,
    # image, font and storage loads across frames and only then goes to the
    # title, so stopping after a fixed handful of frames would report the
    # loading screen as the boot result. Bounded, and it stops early on a caught
    # boot error, so an engine that never becomes ready still returns and its
    # boundary is reported.
    BOOT_PROBE_FRAMES.times do
      break if boot_finished? || !boot_error.empty?
      pump_frame
    end

    @boot_scene = scene_name
    boot_error
  end

  # The boot error `SceneManager.catchException` captured (see #boot_probe), or
  # "" while the boot is healthy.
  def boot_error
    err = MV::JS.eval(
      "(function(){ return (typeof SceneManager !== 'undefined' && " \
      "SceneManager.__mzErr) ? SceneManager.__mzErr : ''; })();"
    )
    err.is_a?(String) ? err : ""
  rescue StandardError => e
    "MV::JS eval failed: #{e.message}"
  end

  attr_reader :boot_scene

  # Report the pending runtime once. Emscripten drives main_loop every frame, so
  # without the guard this would print on each one.
  def warn_runtime_pending
    return if @warned_runtime_pending
    @warned_runtime_pending = true
    $stderr.puts "[MZ] RPG Maker MZ support is under construction: where the " \
                 "WebGL backend is available the engine boots to the title, " \
                 "walks the map, presents frames on-screen and takes input " \
                 "(M6.3), but this build/run has no usable WebGL context (or " \
                 "the boot did not reach a scene), so there is nothing to " \
                 "present. The engine/host/IO/input layers are shared with MV. " \
                 "See docs/adr/0004-javascript-maker-mv-quickjs.md (M6)."
  end
end
