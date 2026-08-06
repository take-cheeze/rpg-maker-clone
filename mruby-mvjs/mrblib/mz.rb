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

  # Frames the message probe lets run after queueing its text, so
  # `Window_Message` can open and draw before the state is read back.
  MSG_PROBE_FRAMES = 45

  # The line the message probe shows. ASCII, so it renders through whatever font
  # the project ships (the test bed's authored one covers ASCII only).
  MESSAGE_PROBE_TEXT = "MZ message smoke test".freeze

  # Frames the menu probe keeps re-asserting `Scene_Map#menuCalling` before it
  # gives up (see #maybe_menu_test).
  MENU_PROBE_FRAMES = 60

  # The common-event probe's bed constants (see #maybe_common_event_test). The
  # bed's common event 1 is parallel, gated on switch 2, and writes variable 3;
  # common event 2 is called by id and writes variable 4.
  COMMON_SWITCH_ID = 2
  COMMON_CALL_ID = 2
  COMMON_PARALLEL_VAR = 3
  COMMON_CALLED_VAR = 4
  COMMON_PROBE_FRAMES = 240

  # Where the transfer probe sends the player, and how long it waits for the
  # destination to load (see #maybe_transfer_test). Map 2 and the tile are the
  # bed's (scripts/gen-mz-sample.py); the wait covers the fade out, the scene
  # re-creation, `DataManager.loadMapData` and the fade back in, all at
  # software-GL speed.
  TRANSFER_MAP_ID = 2
  TRANSFER_X = 4
  TRANSFER_Y = 5
  TRANSFER_PROBE_FRAMES = 300

  # The menu-play probe's setup and bounds (see #maybe_menu_play_test). The
  # party is given `MENU_PLAY_ITEMS` of item `MENU_PLAY_ITEM_ID` and the actor
  # is wounded by `MENU_PLAY_WOUND` HP *before* the menu opens, both through the
  # map interpreter — a healing item is only selectable while someone is hurt,
  # and the party starts with nothing (MZ has no starting-inventory field; a
  # game hands out its first items from an event, which is exactly what the
  # setup runs).
  MENU_PLAY_ITEM_ID = 1
  MENU_PLAY_ITEMS = 3
  MENU_PLAY_WOUND = 300

  # Frames to give the menu play-out, and how often it taps a key. Same edge
  # reasoning as the battle probe: rmmz reports a trigger on the key's edge, so
  # a held key advances one window and then nothing. The bound is generous —
  # every window in the chain fades in, and a headless software-GL frame is
  # slower than 60Hz.
  MENU_PLAY_FRAMES = 900
  MENU_PLAY_TAP_PERIOD = 12

  # Frames the menu-play setup waits for its event commands to take effect
  # before reporting that the bed could not be prepared.
  MENU_PLAY_SETUP_FRAMES = 180

  # The animation the animation probe plays, and how long it keeps replaying it
  # (see #maybe_animation_test). The test bed authors animation 1 as an
  # MV-format burst centred on its target; a project without it logs
  # `cells=0 played=false` rather than pretending.
  ANIM_PROBE_ID = 1
  ANIM_PROBE_FRAMES = 120

  # Frames the save probe waits for its promise chain to settle. MZ's save path
  # is asynchronous end to end (`DataManager.saveGame` -> `StorageManager`'s
  # JSON/deflate/localforage promises), so the result only lands some frames
  # after the probe starts — see #maybe_save_test.
  SAVE_PROBE_FRAMES = 300

  # The save slot the save probe round-trips through.
  SAVE_PROBE_SLOT = 1

  # Frames to watch for `Scene_Battle` after the battle probe runs its Battle
  # Processing command: New Game's fade, the map settle, the encounter effect
  # (~60 frames) and Scene_Battle's own fade-in all have to play out first, and
  # a headless software-GL frame is slower than 60Hz.
  BATTLE_PROBE_FRAMES = 240

  # Frames the battle-play probe drives the fight for before giving up. A turn
  # on software GL costs far more wall clock than it does frames, and the bed's
  # slime takes several of them, so this is generous — it is a give-up bound,
  # not an expected duration (the probe reports the moment the battle ends).
  BATTLE_PLAY_FRAMES = 1200

  # How often the battle-play probe taps confirm, in frames. rmmz's `Input`
  # reports a *trigger* on the edge, so the key has to be released between
  # taps; and the taps have to be slow enough that a window which is not ready
  # yet (mid-animation, mid-message) does not swallow them all.
  BATTLE_PLAY_TAP_PERIOD = 12

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
  # `FontFace` is needed the moment a project names a font: MZ's
  # `FontManager.startLoading` does `new FontFace(family, url)` and waits on its
  # `load()` promise, and an undefined constructor throws inside
  # `Scene_Boot.onDatabaseLoaded`, killing the boot. The shim only has to satisfy
  # that bookkeeping — the glyphs themselves are rasterised natively from the
  # file in the game's `fonts/` dir (mvcanvas.cxx), not through the DOM.
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
    "if (typeof g.FontFace === 'undefined') { " \
    "g.FontFace = function(family, source){ this.family = family; " \
    "this.source = source; this.status = 'loaded'; }; " \
    "g.FontFace.prototype.load = function(){ return Promise.resolve(this); }; } " \
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

    # JS that queues one line of message text through rmmz's `$gameMessage`,
    # the way an event's Show Text command does. `Scene_Map` (a `Scene_Message`)
    # notices the pending text on its next update and opens `Window_Message`
    # over it. Skipped while a message is already busy, so the probe never
    # stacks onto a game's own dialogue. Split out so the injection is
    # unit-testable without a booted engine.
    def message_probe_js(text)
      "(function(){ if (typeof $gameMessage === 'undefined' || !$gameMessage " \
      "|| $gameMessage.isBusy()) return; " \
      "$gameMessage.add(#{js_string(text)}); })();"
    end

    # JS that reads the message state back as "busy=<bool> window_open=<bool>":
    # whether `$gameMessage` still holds text and whether the running scene's
    # `Window_Message` has opened (`openness > 0`). One eval rather than two, so
    # both halves describe the same frame.
    def message_state_js
      "(function(){ var busy = (typeof $gameMessage !== 'undefined' && " \
      "$gameMessage && $gameMessage.isBusy()) ? true : false; " \
      "var s = (typeof SceneManager !== 'undefined') ? SceneManager._scene : " \
      "null; var open = (s && s._messageWindow && s._messageWindow.openness > " \
      "0) ? true : false; return 'busy=' + busy + ' window_open=' + open; })();"
    end

    # JS that asks `Scene_Map` to open the party menu, by setting the very flag
    # its own `updateCallMenu` acts on. rmmz's keyboard `Input.keyMapper` has no
    # "menu" binding (only the gamepad's Y), so pressing a key cannot reach
    # `isMenuCalled`; `menuCalling` is exactly what that predicate sets, so this
    # takes the real `callMenu` path (SoundManager.playOk + push Scene_Menu)
    # from inside the scene loop. Shared shape with MV#maybe_menu_test.
    def menu_probe_js
      "(function(){ var s = (typeof SceneManager !== 'undefined') ? " \
      "SceneManager._scene : null; if (s && s.constructor && " \
      "s.constructor.name === 'Scene_Map') s.menuCalling = true; })();"
    end

    # JS that starts both kinds of common event the way a game does, through the
    # map interpreter: **Control Switches** (code 121) turns on the switch the
    # bed's parallel common event is gated on, and **Call Common Event** (code
    # 117) calls the other one by id.
    #
    # The two are different machinery, which is why both are driven. A parallel
    # common event is not a map event: `Game_CommonEvent` holds an interpreter
    # of its own that `Game_Map.updateEvents` drives, and it only exists while
    # `isActive()` — trigger 2 and the switch on. `command117` instead builds a
    # *child* interpreter inside the calling one, which is the only nesting the
    # interpreter ever does.
    #
    # `[startId, endId, value]` for 121, where value 0 is ON; `[commonEventId]`
    # for 117.
    def common_event_probe_js(switch_id, call_id)
      "(function(){ if (typeof $gameMap === 'undefined' || !$gameMap || " \
      "!$gameMap._interpreter) return; $gameMap._interpreter.setup([" \
      "{code:121,indent:0,parameters:[#{switch_id.to_i},#{switch_id.to_i},0]}," \
      "{code:117,indent:0,parameters:[#{call_id.to_i}]}," \
      "{code:0,indent:0,parameters:[]}], 0); })();"
    end

    # JS that reads the two variables the bed's common events write, plus how
    # many `Game_CommonEvent` objects the map is holding — a parallel common
    # event that never became active leaves the count at zero, which tells the
    # two failure modes apart (the event never ran, versus it ran and its write
    # went nowhere).
    def common_event_state_js(parallel_var, called_var)
      "(function(){ var v = (typeof $gameVariables !== 'undefined' && " \
      "$gameVariables) ? $gameVariables : null; " \
      "var m = (typeof $gameMap !== 'undefined' && $gameMap) ? $gameMap : null; " \
      "var ce = (m && m._commonEvents) ? m._commonEvents.length : -1; " \
      "var live = 0; if (m && m._commonEvents) { " \
      "for (var i = 0; i < m._commonEvents.length; i++) { " \
      "if (m._commonEvents[i]._interpreter) live++; } } " \
      "return 'parallel=' + (v ? v.value(#{parallel_var.to_i}) : -1) + " \
      "' called=' + (v ? v.value(#{called_var.to_i}) : -1) + " \
      "' commons=' + ce + ' active=' + live; })();"
    end

    # JS that leaves the start map the way a game does: a **Transfer Player**
    # event command (code 201) run through the map interpreter, which is what
    # reserves the move and puts the interpreter into its `"transfer"` wait
    # mode. `Scene_Map` then performs it on a later frame — re-creating itself,
    # asking `DataManager.loadMapData` for the destination and setting up that
    # map's own events.
    #
    # `[designation, mapId, x, y, direction, fade]`, designation 0 = direct
    # (1 would read the three from variables), direction 0 = keep facing,
    # fade 0 = black, exactly as the editor emits them.
    def transfer_probe_js(map_id, x, y)
      "(function(){ if (typeof $gameMap === 'undefined' || !$gameMap || " \
      "!$gameMap._interpreter) return; $gameMap._interpreter.setup([" \
      "{code:201,indent:0,parameters:[0,#{map_id.to_i},#{x.to_i}," \
      "#{y.to_i},0,0]}," \
      "{code:0,indent:0,parameters:[]}], 0); })();"
    end

    # JS that reads the transfer back: which map is loaded, where the player
    # stands, and the variable the *destination* map's own parallel event
    # writes.
    #
    # That last field is the point. `$gameMap.mapId()` moving proves the id
    # changed; it does not prove the new map's data was fetched or that its
    # events were set up. The bed's second map runs a parallel event writing
    # variable 2, which only ever becomes non-zero if the arriving map really
    # loaded and its interpreter is running — see scripts/gen-mz-sample.py.
    def transfer_state_js
      "(function(){ var m = (typeof $gameMap !== 'undefined' && $gameMap) ? " \
      "$gameMap.mapId() : -1; " \
      "var p = (typeof $gamePlayer !== 'undefined' && $gamePlayer) ? " \
      "$gamePlayer : null; " \
      "var v = (typeof $gameVariables !== 'undefined' && $gameVariables) ? " \
      "$gameVariables.value(2) : -1; " \
      "var ev = (typeof $gameMap !== 'undefined' && $gameMap && " \
      "$gameMap.events) ? $gameMap.events().length : -1; " \
      "return 'map=' + m + ' x=' + (p ? p.x : -1) + ' y=' + (p ? p.y : -1) + " \
      "' arrived=' + v + ' events=' + ev; })();"
    end

    # JS that sets the menu-play probe's starting condition the way a game
    # does: **Change Items** (code 126) and **Change HP** (code 311) run
    # through the *map interpreter*, not by reaching into `$gameParty` and
    # `$gameActors` from outside. Same reasoning as the battle probe's code
    # 301 — the engine path a real project takes is the one worth driving, and
    # `command126`/`command311` are where the party inventory and an actor's HP
    # are actually written.
    #
    # `[itemId, operation, operandType, operand]` for 126 and
    # `[actorSource, actorId, operation, operandType, operand, allowDeath]` for
    # 311, both with operation 0 = increase / 1 = decrease and operand type
    # 0 = constant, exactly as the editor emits them.
    def menu_play_setup_js(item_id, count, wound)
      "(function(){ if (typeof $gameMap === 'undefined' || !$gameMap || " \
      "!$gameMap._interpreter) return; $gameMap._interpreter.setup([" \
      "{code:126,indent:0,parameters:[#{item_id.to_i},0,0,#{count.to_i}]}," \
      "{code:311,indent:0,parameters:[0,1,1,0,#{wound.to_i},false]}," \
      "{code:0,indent:0,parameters:[]}], 0); })();"
    end

    # JS that reads back what the menu play-out is doing: the first actor's HP,
    # how many of the probe's item the party holds, and which window currently
    # has the cursor.
    #
    # The window is read by walking the scene's own window layer and reporting
    # the first *active* `Window_Selectable` rather than by naming the fields of
    # each scene (`_categoryWindow`, `_itemWindow`, `_actorWindow`, …): the
    # chain crosses two scenes, and a flow that stalls stalls *somewhere* — the
    # constructor name says where without the probe having to enumerate every
    # place it could be.
    def menu_play_state_js(item_id)
      "(function(){ var hp = -1, mhp = -1, n = -1; " \
      "if (typeof $gameActors !== 'undefined' && $gameActors) { " \
      "var a = $gameActors.actor(1); if (a) { hp = a.hp; mhp = a.mhp; } } " \
      "if (typeof $gameParty !== 'undefined' && $gameParty && " \
      "typeof $dataItems !== 'undefined' && $dataItems[#{item_id.to_i}]) " \
      "n = $gameParty.numItems($dataItems[#{item_id.to_i}]); " \
      "var s = (typeof SceneManager !== 'undefined') ? SceneManager._scene : " \
      "null; var w = '', idx = -1; " \
      "var layer = s ? s._windowLayer : null; " \
      "var kids = layer ? layer.children : null; " \
      "if (kids) { for (var i = 0; i < kids.length; i++) { var c = kids[i]; " \
      "if (c && c.active && c.constructor && c.index) { " \
      "w = c.constructor.name; idx = c.index(); break; } } } " \
      "return 'hp=' + hp + ' mhp=' + mhp + ' items=' + n + " \
      "' win=' + (w || '-') + ' idx=' + idx; })();"
    end

    # JS that asks for an animation on the player through `$gameTemp`, exactly
    # as an event's Show Animation command does — `Spriteset_Map` drains the
    # queue on its next update and builds the sprite. Re-requested only while
    # nothing is playing, so the probe keeps one burst on screen continuously
    # rather than stacking a fresh sprite every frame (the screenshot has to
    # land during one; see #maybe_animation_test).
    def animation_probe_js(id)
      "(function(){ if (typeof $gameTemp === 'undefined' || !$gameTemp) " \
      "return; if (typeof $gamePlayer === 'undefined' || !$gamePlayer) " \
      "return; var s = (typeof SceneManager !== 'undefined') ? " \
      "SceneManager._scene : null; var ss = s ? s._spriteset : null; " \
      "if (!ss || ss.isAnimationPlaying()) return; " \
      "$gameTemp.requestAnimation([$gamePlayer], #{id.to_i}); })();"
    end

    # JS that reads the animation back as
    # "data=<bool> mv=<bool> sprites=<n> cells=<n>". `cells` is the one that
    # matters: it counts `Sprite_AnimationMV` cell sprites that are visible and
    # carry a bitmap this frame, so it is the difference between a sprite that
    # exists in the scene graph and one that is actually drawing. `mv` reports
    # which of MZ's two animation systems the data selected —
    # `Spriteset_Base.isMVAnimation` picks the sprite-sheet path when the
    # animation has `frames`, and the Effekseer path otherwise, which needs a
    # WASM runtime our host does not start (ADR 0004 M6.3h).
    def animation_state_js(id)
      "(function(){ var a = (typeof $dataAnimations !== 'undefined' && " \
      "$dataAnimations) ? $dataAnimations[#{id.to_i}] : null; " \
      "var s = (typeof SceneManager !== 'undefined') ? SceneManager._scene : " \
      "null; var ss = s ? s._spriteset : null; " \
      "var list = (ss && ss._animationSprites) ? ss._animationSprites : []; " \
      "var cells = 0; for (var i = 0; i < list.length; i++) { " \
      "var cs = list[i]._cellSprites || []; for (var j = 0; j < cs.length; " \
      "j++) { if (cs[j].visible && cs[j].bitmap) cells++; } } " \
      "return 'data=' + (a ? true : false) + ' mv=' + ((a && a.frames) ? " \
      "true : false) + ' sprites=' + list.length + ' cells=' + cells; })();"
    end

    # JS that starts a save + load round-trip through the real `DataManager` and
    # parks the outcome on `__mzSaveResult` for #maybe_save_test to read back.
    #
    # Unlike MV's — which is synchronous — **MZ's save path is a promise
    # chain**: `DataManager.saveGame` returns `StorageManager.saveObject(...)`,
    # itself `objectToJson` -> `jsonToZip` (pako) -> `saveZip` -> localforage,
    # and `loadGame` mirrors it. So the probe cannot read a return value; it
    # kicks the chain off and the result appears frames later, once the host has
    # pumped enough microtasks. `savefileExists` is read *after* the save
    # resolves, because `saveToForage` only refreshes `StorageManager`'s key
    # cache at the end of its own chain.
    #
    # The load re-creates the `$game*` objects from the file, so the probe
    # finishes the way a real load does — `SceneManager.goto(Scene_Map)` — and
    # the running scene is rebuilt against the restored objects instead of
    # holding references to the ones the load threw away.
    def save_probe_js(slot)
      slot = slot.to_i
      <<~JS
        (function () {
          globalThis.__mzSaveResult = "";
          if (typeof DataManager === "undefined") {
            globalThis.__mzSaveResult = "error: no DataManager"; return;
          }
          var fail = function (e) {
            globalThis.__mzSaveResult =
              "error: " + String((e && e.message) || e);
          };

          // One line covering the save's main contents: the party (gold and
          // inventory), an actor (HP), the switch and variable tables, and the
          // player's position on the map. Read before saving and again after
          // loading; the round-trip is only a round-trip if they match.
          var sig = function () {
            var a = $gameActors ? $gameActors.actor(1) : null;
            var it = (typeof $dataItems !== "undefined") ? $dataItems[1] : null;
            return "gold=" + $gameParty.gold() +
              " sw=" + ($gameSwitches.value(1) ? 1 : 0) +
              " var=" + $gameVariables.value(1) +
              " hp=" + (a ? a.hp : -1) +
              " items=" + (it ? $gameParty.numItems(it) : -1) +
              " pos=" + $gamePlayer.x + "," + $gamePlayer.y;
          };

          // Move every field off its default *before* saving. Without this the
          // check would pass on an engine that quietly started a new game
          // instead of loading one: a fresh game's state and an unwritten
          // save's state would both read as the defaults. (These are the same
          // calls the editor's Change Gold / Control Switches / Control
          // Variables / Change Items / Change HP commands make. Unlike the
          // menu probe, which drives them through the interpreter because a
          // game really does hand out its first items from an event, how this
          // state came to exist has no bearing on whether it serialises.)
          var arm = function () {
            $gameParty.gainGold(1234);
            $gameSwitches.setValue(1, true);
            $gameVariables.setValue(1, 4321);
            if (typeof $dataItems !== "undefined" && $dataItems[1]) {
              $gameParty.gainItem($dataItems[1], 5);
            }
            var a = $gameActors ? $gameActors.actor(1) : null;
            if (a) { a.setHp(Math.max(1, a.mhp - 111)); }
            $gamePlayer.locate(3, 4);
          };

          // Overwrite all of it between the save and the load, so a load that
          // restores nothing cannot be mistaken for one that restored
          // everything. Every field moves somewhere the armed state is not.
          var clobber = function () {
            $gameParty.gainGold(777);
            $gameSwitches.setValue(1, false);
            $gameVariables.setValue(1, 9999);
            if (typeof $dataItems !== "undefined" && $dataItems[1]) {
              $gameParty.loseItem($dataItems[1], 2);
            }
            var a = $gameActors ? $gameActors.actor(1) : null;
            if (a) { a.setHp(Math.max(1, a.hp - 37)); }
            $gamePlayer.locate(11, 9);
          };

          try {
            var exists = false;
            arm();
            var before = sig();
            DataManager.saveGame(#{slot}).then(function () {
              exists = !!DataManager.savefileExists(#{slot});
              clobber();
              return DataManager.loadGame(#{slot});
            }).then(function () {
              var after = sig();
              globalThis.__mzSaveResult =
                "saved=true exists=" + exists + " loaded=true restored=" +
                (after === before) +
                (after === before ? "" :
                  " before=[" + before + "] after=[" + after + "]");
              try {
                if (typeof SceneManager !== "undefined" &&
                    typeof Scene_Map !== "undefined") {
                  SceneManager.goto(Scene_Map);
                }
              } catch (e) {
                // The round-trip itself succeeded, so its verdict is kept; the
                // re-entry failure is appended rather than swallowed.
                globalThis.__mzSaveResult +=
                  " goto_error=" + String((e && e.message) || e);
              }
            })["catch"](fail);
          } catch (e) { fail(e); }
        })();
      JS
    end

    # JS that reads back what #save_probe_js parked, or "" while the promise
    # chain is still in flight.
    def save_result_js
      "(function(){ return (typeof __mzSaveResult === 'string') ? " \
      "__mzSaveResult : ''; })();"
    end

    # JS that starts a battle against `troop_id` the way a game does: a **Battle
    # Processing** event command (code 301) run through the *map interpreter*,
    # not a bare `SceneManager.push(Scene_Battle)` from outside the scene loop.
    # The bare push deadlocks — `Scene_Map.stop` starts the encounter effect,
    # which only advances while the scene is inactive, so an out-of-loop push
    # leaves the map active with the effect frozen and the pending battle never
    # applies. rmmz's `command301` takes the same `[type, troopId, canEscape,
    # canLose]` parameters as rmmv's, so the injected list is shared in shape
    # with MV#maybe_battle_test.
    def battle_probe_js(troop_id)
      "(function(){ if (typeof $gameMap === 'undefined' || !$gameMap || " \
      "!$gameMap._interpreter) return; $gameMap._interpreter.setup([" \
      "{code:301,indent:0,parameters:[0,#{troop_id.to_i},true,false]}," \
      "{code:0,indent:0,parameters:[]}], 0); })();"
    end

    # JS that reads the fight back as
    # "hp=<n> max=<n> phase=<s> alive=<n>": the troop's total remaining HP and
    # its total max HP, `BattleManager`'s phase, and how many enemies are still
    # standing. Read once a frame by #maybe_battle_play_test, which needs only
    # to watch the total fall — the damage formula's exact numbers are the
    # game's business, not the smoke test's.
    def battle_state_js
      "(function(){ if (typeof $gameTroop === 'undefined' || !$gameTroop || " \
      "!$gameTroop.members) return 'hp=-1 max=-1 alive=-1 phase= win= input=0'; " \
      "var m = $gameTroop.members(); var hp = 0, mx = 0, alive = 0; " \
      "for (var i = 0; i < m.length; i++) { hp += m[i].hp; mx += m[i].mhp; " \
      "if (m[i].isAlive()) alive++; } " \
      "var bm = (typeof BattleManager !== 'undefined') ? BattleManager : null; " \
      "var p = bm ? (bm._phase || '') : ''; " \
      "var inp = (bm && bm.isInputting && bm.isInputting()) ? 1 : 0; " \
      "var s = (typeof SceneManager !== 'undefined') ? SceneManager._scene : " \
      "null; var w = ''; if (s) { " \
      "if (s._partyCommandWindow && s._partyCommandWindow.active) w = 'party'; " \
      "else if (s._actorCommandWindow && s._actorCommandWindow.active) " \
      "w = 'actor'; " \
      "else if (s._enemyWindow && s._enemyWindow.active) w = 'enemy'; " \
      "else if (s._skillWindow && s._skillWindow.active) w = 'skill'; " \
      "else if (s._itemWindow && s._itemWindow.active) w = 'item'; } " \
      "var msg = (typeof $gameMessage !== 'undefined' && $gameMessage && " \
      "$gameMessage.isBusy()) ? 1 : 0; " \
      "var mo = (s && s._messageWindow) ? s._messageWindow.openness : -1; " \
      "var busy = (bm && bm.isBusy && bm.isBusy()) ? 1 : 0; " \
      "return 'hp=' + hp + ' max=' + mx + ' alive=' + alive + ' phase=' + p + " \
      "' win=' + w + ' input=' + inp + ' msg=' + msg + ' mopen=' + mo + " \
      "' busy=' + busy; })();"
    end

    # Pull one `key=value` field out of a probe's state string as an Integer,
    # or nil when the field is absent. The state strings are built above, so
    # this is parsing our own format, not the engine's.
    def state_field(state, key)
      part = state.to_s.split("#{key}=")[1]
      return nil if part.nil?

      part.split(" ")[0].to_i
    end

    # Quote a Ruby string as a single-quoted JavaScript string literal, escaping
    # what would otherwise end or reopen it (backslash, quote, newline). The
    # probe text is ASCII at every call site, so nothing else needs encoding.
    def js_string(text)
      escaped = text.to_s.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")
                    .gsub("\n", "\\n")
      "'#{escaped}'"
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
    maybe_battle_test # CI: start a battle from the map and log Scene_Battle
    maybe_battle_play_test # CI: play that battle out and log the fight resolved
    maybe_move_test # CI: hold a direction on the map and log that the player moved
    maybe_message_test # CI: show a message on the map and log the window opened
    maybe_animation_test # CI: play an animation on the player and log it drew
    maybe_transfer_test # CI: Transfer Player to map 2 and log that it loaded
    maybe_common_event_test # CI: run both kinds of common event and log each
    maybe_menu_play_setup # CI: arm the party (item + a wound) before the menu
    maybe_menu_test # CI: open the menu on the map and log that Scene_Menu opened
    maybe_menu_play_test # CI: use that menu and log the item healed and was spent
    maybe_save_test # CI: save+load round-trip on the map and log the result
    maybe_audio_test # CI: play an SE through the bridge and log it dispatched
    present
    maybe_screenshot # capture the presented frame once, if requested (CI)
    RGSS::Input.update
    RGSS::Graphics.update
    finish_when_probes_done # CI: stop once every probe has had its say
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

  # When --mz_new_game is set (CI) — or any probe that needs the map first is
  # requested — pick "New Game" once the title is up, so the game advances to
  # its start map without any input and a headless run exercises the in-game
  # render path instead of only the title. One-shot; a no-op during normal play
  # (flags unset). Mirrors MV#maybe_new_game.
  def maybe_new_game
    return if @new_game_done
    return unless new_game_requested? || move_test_requested? ||
                  audio_test_requested? || message_test_requested? ||
                  menu_test_requested? || save_test_requested? ||
                  animation_test_requested? || battle_test_troop > 0 ||
                  transfer_test_requested? || common_event_test_requested?
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

  # Whether --mz_message_test was requested (a launcher constant set by
  # main.cxx). Implies New Game, since the probe needs the map.
  def message_test_requested?
    (begin
      MZ_MESSAGE_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_message_test is set (CI), once on the map queue a "Show Text"
  # message through `$gameMessage`, let `Scene_Map`'s `Window_Message` open and
  # draw it over a few frames, then log whether the window opened and is still
  # showing the text. This drives the dialogue path every RPG uses (event ->
  # $gameMessage -> Window_Message -> the native text render), so a headless run
  # proves message boxes actually display rather than only that the map renders.
  # One-shot; a no-op during normal play. Mirrors MV#maybe_message_test.
  def maybe_message_test
    return if @msg_test_done
    return unless message_test_requested?
    return unless current_scene == "Scene_Map"

    @msg_frame ||= 0
    if @msg_frame.zero?
      MV::JS.eval(self.class.message_probe_js(MESSAGE_PROBE_TEXT))
      $stderr.puts "[MZ] auto message test: queued a message"
    end
    @msg_frame += 1
    return if @msg_frame < MSG_PROBE_FRAMES

    @msg_test_done = true
    state = MV::JS.eval(self.class.message_state_js)
    $stderr.puts "[MZ-MSG] #{state.is_a?(String) ? state : ""}"
  rescue StandardError => e
    $stderr.puts "[MZ] message test error: #{e.message}"
  end

  # Whether --mz_battle_play was requested (a launcher constant set by
  # main.cxx). Implies --mz_battle_test, since it plays out the fight that
  # starts.
  def battle_play_requested?
    (begin
      MZ_BATTLE_PLAY
    rescue StandardError
      false
    end) == true
  end

  # When --mz_battle_play is set (CI), once `Scene_Battle` is up, *play* the
  # fight: tap confirm until the enemy's HP falls and the battle ends.
  #
  # The existing battle probe proves combat can be **entered**, which is a
  # different and much smaller claim than combat working. Everything between
  # the two is untested by it: `Window_PartyCommand` taking Fight,
  # `Window_ActorCommand` taking Attack, the enemy-target window,
  # `BattleManager`'s turn order, the action's damage formula reaching an
  # enemy's HP, the battle log, and the victory sequence that hands the scene
  # back to the map.
  #
  # It drives that with real key presses rather than by calling the scene's
  # methods, unlike the menu probe: the command windows *are* what is being
  # tested here, so reaching past them into `BattleManager` would test the part
  # that was already working. Confirm is tapped rather than held because rmmz
  # reports a trigger on the key's edge, so a held key advances one window and
  # then nothing.
  #
  # The report is one-shot, and it lands the moment the battle ends rather than
  # at the frame bound, so a fight that finishes early does not stall the run.
  def maybe_battle_play_test
    return if @btl_play_done
    return unless battle_play_requested?
    return unless current_scene == "Scene_Battle" || @btl_play_started

    @btl_play_frame ||= 0
    state = MV::JS.eval(self.class.battle_state_js)
    hp = MZ.state_field(state, "hp")
    alive = MZ.state_field(state, "alive")

    if @btl_play_frame.zero?
      @btl_play_started = true
      @btl_play_hp0 = hp
      $stderr.puts "[MZ] auto battle play: troop hp #{@btl_play_hp0}"
    end
    @btl_play_frame += 1
    @btl_play_damaged ||= !@btl_play_hp0.nil? && !hp.nil? &&
                          @btl_play_hp0 > 0 && hp < @btl_play_hp0
    @btl_play_hp = hp
    @btl_play_alive = alive
    @btl_play_state = state

    # Trace on change rather than on a timer: a fight that is progressing prints
    # a handful of lines (the phase and the active window move), and one that is
    # wedged prints nothing after the first — which is the diagnosis.
    if state != @btl_play_last_state
      @btl_play_last_state = state
      $stderr.puts "[MZ-BTLPLAY] state #{state}"
    end

    # Tap confirm: one frame down per period, released the rest of the time.
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.press(RGSS::Input::C) if (@btl_play_frame % BATTLE_PLAY_TAP_PERIOD).zero?

    # The battle is over when the scene has handed back to the map.
    ended = @btl_play_started && current_scene == "Scene_Map"
    return if !ended && @btl_play_frame < BATTLE_PLAY_FRAMES

    @btl_play_done = true
    RGSS::Input.release(RGSS::Input::C)
    $stderr.puts "[MZ-BTLPLAY] hp_before=#{@btl_play_hp0} hp_after=#{@btl_play_hp} " \
                 "alive=#{@btl_play_alive} damaged=#{@btl_play_damaged ? true : false} " \
                 "ended=#{ended ? true : false} scene=#{current_scene} " \
                 "last=[#{@btl_play_state}]"
  rescue StandardError => e
    $stderr.puts "[MZ] battle play error: #{e.message}"
  end

  # Whether --mz_animation_test was requested (a launcher constant set by
  # main.cxx). Implies New Game, since the probe plays on the map.
  def animation_test_requested?
    (begin
      MZ_ANIMATION_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_animation_test is set (CI), once on the map play an animation on
  # the player through `$gameTemp.requestAnimation` — the same call an event's
  # Show Animation command makes — and log whether cells actually drew.
  #
  # This is the one in-game system the other probes never touch, and MZ has two
  # of them. `Spriteset_Base.isMVAnimation` routes by data shape: an animation
  # carrying a `frames` array is drawn by `Sprite_AnimationMV` out of a sprite
  # sheet, anything else by `Sprite_Animation`, which plays through an Effekseer
  # WASM runtime `main.js` starts and our host does not (ADR 0004 M6.2). So the
  # reachable path is the MV-format one, and what it exercises that nothing else
  # here does is per-sprite blend modes — the bed's animation ends on an
  # additive frame for exactly that reason.
  #
  # The animation is re-requested whenever none is playing, so a burst is on
  # screen continuously for the ~2 seconds the probe runs. That is deliberate:
  # the run captures a single frame, and an animation that played once early
  # would be long over by then, leaving a screenshot that proves nothing. The
  # report is one-shot; `@anim_cells_seen` also gates the screenshot, so the
  # capture lands on a frame with cells in it.
  def maybe_animation_test
    return if @anim_test_done
    return unless animation_test_requested?
    return unless current_scene == "Scene_Map"

    @anim_frame ||= 0
    $stderr.puts "[MZ] auto animation test" if @anim_frame.zero?
    @anim_frame += 1
    MV::JS.eval(self.class.animation_probe_js(ANIM_PROBE_ID))
    state = MV::JS.eval(self.class.animation_state_js(ANIM_PROBE_ID))
    @anim_state = state if state.is_a?(String)
    # Cells drawing *this* frame gates the screenshot; cells drawing at any
    # point is what gets reported.
    @anim_cells_now = @anim_state.to_s.split("cells=").last.to_i.positive?
    @anim_cells_seen ||= @anim_cells_now
    return if @anim_frame < ANIM_PROBE_FRAMES

    @anim_test_done = true
    $stderr.puts "[MZ-ANIM] #{@anim_state} played=#{@anim_cells_seen ? true : false}"
  rescue StandardError => e
    $stderr.puts "[MZ] animation test error: #{e.message}"
  end

  # Whether --mz_menu_test was requested (a launcher constant set by main.cxx).
  # Implies New Game, since the probe opens the menu from the map.
  def menu_test_requested?
    (begin
      MZ_MENU_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_menu_test is set (CI), once on the map open the party menu through
  # `Scene_Map`'s own `callMenu` (see MZ.menu_probe_js) and log whether
  # `Scene_Menu` actually opened. This drives the menu path every RPG uses (map
  # -> Scene_Menu -> its command / status / gold windows, each of them a
  # `Window_Selectable` whose rows stroke a background rect), so a headless run
  # proves the menu opens and draws.
  #
  # The flag is re-asserted every frame rather than set once: `updateCallMenu`
  # clears `menuCalling` on any frame the menu is momentarily disabled (an
  # autorun event, or the New Game transfer still settling right after the map
  # arrives), so a single set can be dropped before it ever fires. One-shot
  # report. Mirrors MV#maybe_menu_test.
  def maybe_menu_test
    return if @menu_test_done
    return unless menu_test_requested?
    # With --mz_menu_play the menu has to open onto a prepared party, so the
    # menu waits for #maybe_menu_play_setup. It would not open during the setup
    # event anyway (`updateCallMenu` disables the menu while an event runs), so
    # without this the probe would burn its whole frame budget being ignored.
    return if menu_play_requested? && !@menu_play_ready
    return unless @menu_requested || current_scene == "Scene_Map"

    if current_scene == "Scene_Menu"
      @menu_test_done = true
      $stderr.puts "[MZ-MENU] reached_menu=true"
      return
    end

    @menu_frame ||= 0
    $stderr.puts "[MZ] auto menu test" if @menu_frame.zero?
    @menu_frame += 1
    @menu_requested = true
    MV::JS.eval(self.class.menu_probe_js)
    return if @menu_frame < MENU_PROBE_FRAMES

    @menu_test_done = true
    $stderr.puts "[MZ-MENU] reached_menu=false scene=#{current_scene}"
  rescue StandardError => e
    $stderr.puts "[MZ] menu test error: #{e.message}"
  end

  # Whether --mz_common_event_test was requested (a launcher constant set by
  # main.cxx). Implies New Game, since both common events are started from the
  # map.
  def common_event_test_requested?
    (begin
      MZ_COMMON_EVENT_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_common_event_test is set (CI), once on the map turn on the switch
  # the bed's parallel common event is gated on and call the other common event
  # by id, then log whether each one actually ran.
  #
  # Common events are a core feature with no coverage at all until now, because
  # the bed's `CommonEvents.json` was empty. They are also two separate paths:
  # the parallel one runs on an interpreter `Game_CommonEvent` owns and
  # `Game_Map.updateEvents` drives, existing only while its switch is on; the
  # called one runs on a *child* interpreter nested inside the caller. A probe
  # that drove only one of them would leave the other untouched, so this drives
  # both and reports them separately.
  def maybe_common_event_test
    return if @common_test_done
    return unless common_event_test_requested?
    return unless @common_started || current_scene == "Scene_Map"

    @common_frame ||= 0
    if @common_frame.zero?
      @common_started = true
      $stderr.puts "[MZ] auto common event test: switch #{COMMON_SWITCH_ID}, " \
                   "call #{COMMON_CALL_ID}"
      MV::JS.eval(
        self.class.common_event_probe_js(COMMON_SWITCH_ID, COMMON_CALL_ID)
      )
    end
    @common_frame += 1

    state = MV::JS.eval(
      self.class.common_event_state_js(COMMON_PARALLEL_VAR, COMMON_CALLED_VAR)
    )
    if state != @common_last_state
      @common_last_state = state
      $stderr.puts "[MZ-COMMON] state #{state}"
    end

    parallel = MZ.state_field(state, "parallel").to_i.positive?
    called = MZ.state_field(state, "called").to_i.positive?
    return if !(parallel && called) && @common_frame < COMMON_PROBE_FRAMES

    @common_test_done = true
    $stderr.puts "[MZ-COMMON] parallel=#{parallel ? true : false} " \
                 "called=#{called ? true : false} last=[#{state}]"
  rescue StandardError => e
    $stderr.puts "[MZ] common event test error: #{e.message}"
  end

  # Whether --mz_transfer_test was requested (a launcher constant set by
  # main.cxx). Implies New Game, since the transfer starts from the map.
  def transfer_test_requested?
    (begin
      MZ_TRANSFER_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_transfer_test is set (CI), once on the start map run a Transfer
  # Player command to the bed's second map and log whether the destination
  # actually loaded.
  #
  # This is the first thing in the MZ line that leaves `Map001`. Everything
  # about arriving somewhere else is its own path — `Game_Player.reserveTransfer`
  # and the interpreter's `"transfer"` wait, `Scene_Map` tearing itself down and
  # re-creating, `DataManager.loadMapData` fetching a `MapXXX.json` that was
  # never read at boot, a fresh `Spriteset_Map` over a different tile layout,
  # and `Game_Map.setupEvents` for the arriving map's events — and a bed with
  # one map exercises none of it.
  #
  # Three claims, in increasing strength: the map id moved, the player is
  # standing on the requested tile, and the destination's *own* parallel event
  # has run (`arrived=`). The last is what separates "the id changed" from "the
  # map loaded and is running" — see MZ.transfer_state_js.
  def maybe_transfer_test
    return if @transfer_test_done
    return unless transfer_test_requested?
    return unless @transfer_started || current_scene == "Scene_Map"

    @transfer_frame ||= 0
    if @transfer_frame.zero?
      @transfer_started = true
      @transfer_from = MV::JS.eval(self.class.transfer_state_js)
      $stderr.puts "[MZ] auto transfer test: from #{@transfer_from}"
      MV::JS.eval(
        self.class.transfer_probe_js(TRANSFER_MAP_ID, TRANSFER_X, TRANSFER_Y)
      )
    end
    @transfer_frame += 1

    state = MV::JS.eval(self.class.transfer_state_js)
    if state != @transfer_last_state
      @transfer_last_state = state
      $stderr.puts "[MZ-XFER] state #{state}"
    end

    map = MZ.state_field(state, "map")
    x = MZ.state_field(state, "x")
    y = MZ.state_field(state, "y")
    arrived = MZ.state_field(state, "arrived")
    landed = map == TRANSFER_MAP_ID && x == TRANSFER_X && y == TRANSFER_Y
    # The destination's event needs a frame or two of its own after the
    # transfer, so the report waits for it rather than latching the moment the
    # map id moves.
    return if !(landed && arrived.to_i.positive?) &&
              @transfer_frame < TRANSFER_PROBE_FRAMES

    @transfer_test_done = true
    $stderr.puts "[MZ-XFER] from=[#{@transfer_from}] to=[#{state}] " \
                 "moved=#{map == TRANSFER_MAP_ID ? true : false} " \
                 "landed=#{landed ? true : false} " \
                 "arrived=#{arrived.to_i.positive? ? true : false} " \
                 "scene=#{current_scene}"
  rescue StandardError => e
    $stderr.puts "[MZ] transfer test error: #{e.message}"
  end

  # Whether --mz_menu_play was requested (a launcher constant set by main.cxx).
  # Implies --mz_menu_test, since the play-out starts from the open menu.
  def menu_play_requested?
    (begin
      MZ_MENU_PLAY
    rescue StandardError
      false
    end) == true
  end

  # When --mz_menu_play is set (CI), give the party the probe's item and wound
  # the actor while still on the map, then let the menu open (see
  # #maybe_menu_test). Both go through the map interpreter as the event commands
  # a game would use — see MZ.menu_play_setup_js.
  #
  # A menu opened onto the bed's untouched party has nothing to do: the party
  # holds no items, and even holding one, a full-HP actor greys the row out
  # (`Game_Action.testApply`) and confirm buzzes. The setup is what makes the
  # play-out a test of the menu rather than of an empty list.
  #
  # If the setup never takes it gives up rather than blocking the menu forever;
  # the play report then lands with `healed=false`, which fails the check
  # loudly instead of the run timing out with nothing said.
  def maybe_menu_play_setup
    return if @menu_play_ready
    return unless menu_play_requested?
    return unless current_scene == "Scene_Map"

    @menu_setup_frame ||= 0
    if @menu_setup_frame.zero?
      $stderr.puts "[MZ] auto menu play: preparing the party"
      MV::JS.eval(
        self.class.menu_play_setup_js(MENU_PLAY_ITEM_ID, MENU_PLAY_ITEMS,
                                      MENU_PLAY_WOUND)
      )
    end
    @menu_setup_frame += 1

    state = MV::JS.eval(self.class.menu_play_state_js(MENU_PLAY_ITEM_ID))
    hp = MZ.state_field(state, "hp")
    mhp = MZ.state_field(state, "mhp")
    items = MZ.state_field(state, "items")

    if !hp.nil? && !mhp.nil? && hp.positive? && hp < mhp && items.to_i.positive?
      @menu_play_ready = true
      @menu_play_hp0 = hp
      @menu_play_items0 = items
      $stderr.puts "[MZ-MENUPLAY] setup #{state}"
      return
    end
    return if @menu_setup_frame < MENU_PLAY_SETUP_FRAMES

    @menu_play_ready = true
    $stderr.puts "[MZ-MENUPLAY] setup never took: #{state}"
  rescue StandardError => e
    $stderr.puts "[MZ] menu play setup error: #{e.message}"
  end

  # When --mz_menu_play is set (CI), once `Scene_Menu` is up, *use* it: tap
  # confirm through the command window (Item), the item category, the item list
  # and the actor window until the potion is spent and the actor's HP rises,
  # then tap cancel back out until the map returns.
  #
  # The existing menu probe proves the menu can be **opened**, which is a much
  # smaller claim than the menu working — it holds the instant `Scene_Menu` is
  # pushed, before the scene's first update. Everything a player does with the
  # menu is untested by it: `Window_MenuCommand` taking a command,
  # `Scene_Item`'s category and item lists, an item's effects reaching an
  # actor's HP through `Game_Action`, the inventory losing the consumed item,
  # and cancel unwinding the whole stack back to the map.
  #
  # Like the battle play-out this drives real key presses rather than calling
  # the scenes' methods: the windows *are* what is under test, so reaching past
  # them into `Game_Party#consumeItem` would test the part that already worked.
  #
  # The report is one-shot and lands the moment the map comes back, so a run
  # that finishes early does not stall.
  def maybe_menu_play_test
    return if @menu_play_done
    return unless menu_play_requested?
    return unless @menu_play_started || current_scene == "Scene_Menu"

    @menu_play_frame ||= 0
    state = MV::JS.eval(self.class.menu_play_state_js(MENU_PLAY_ITEM_ID))
    hp = MZ.state_field(state, "hp")
    items = MZ.state_field(state, "items")

    if @menu_play_frame.zero?
      @menu_play_started = true
      $stderr.puts "[MZ] auto menu play: #{state}"
    end
    @menu_play_frame += 1
    @menu_play_hp = hp
    @menu_play_items = items
    @menu_play_state = state
    @menu_play_healed ||= !hp.nil? && !@menu_play_hp0.nil? &&
                          hp > @menu_play_hp0
    @menu_play_used ||= !items.nil? && !@menu_play_items0.nil? &&
                        items < @menu_play_items0
    # Latched for the screenshot: the target window is the frame worth keeping
    # (see #menu_play_shot_ready?).
    @menu_play_at_actor ||= state.to_s.include?("win=Window_MenuActor")

    # Trace on change rather than on a timer: a menu that is being walked prints
    # a line per window, and one that is stuck prints nothing after the first —
    # which is the diagnosis.
    if state != @menu_play_last_state
      @menu_play_last_state = state
      $stderr.puts "[MZ-MENUPLAY] state #{state}"
    end

    # Confirm walks in; once the item has actually been spent, cancel walks the
    # window stack back out to the map. Both are tapped, not held, for the same
    # edge-trigger reason as the battle probe.
    used = @menu_play_healed && @menu_play_used
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.release(RGSS::Input::B)
    if (@menu_play_frame % MENU_PLAY_TAP_PERIOD).zero?
      RGSS::Input.press(used ? RGSS::Input::B : RGSS::Input::C)
    end

    returned = used && current_scene == "Scene_Map"
    return if !returned && @menu_play_frame < MENU_PLAY_FRAMES

    @menu_play_done = true
    RGSS::Input.release(RGSS::Input::C)
    RGSS::Input.release(RGSS::Input::B)
    $stderr.puts "[MZ-MENUPLAY] hp_before=#{@menu_play_hp0} " \
                 "hp_after=#{@menu_play_hp} items_before=#{@menu_play_items0} " \
                 "items_after=#{@menu_play_items} " \
                 "healed=#{@menu_play_healed ? true : false} " \
                 "used=#{@menu_play_used ? true : false} " \
                 "returned=#{returned ? true : false} scene=#{current_scene} " \
                 "last=[#{@menu_play_state}]"
  rescue StandardError => e
    $stderr.puts "[MZ] menu play error: #{e.message}"
  end

  # Whether --mz_save_test was requested (a launcher constant set by main.cxx).
  # Implies New Game, since the probe saves the state the map set up.
  def save_test_requested?
    (begin
      MZ_SAVE_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mz_save_test is set (CI), once on the map run a save + load
  # round-trip through the real `DataManager` and log the result. This drives
  # the save path every game relies on: `makeSaveContents` serialises the
  # `$game*` objects, `StorageManager` deflates them through pako and writes the
  # slot, `savefileExists` confirms it, and `loadGame` reads it back and rebuilds
  # the game objects.
  #
  # MZ's chain is asynchronous (unlike MV's), so the probe starts it once and
  # then polls `__mzSaveResult` on later frames — each pumped frame drains the
  # promise microtasks the chain waits on. A chain that never settles is
  # reported as a timeout rather than silently ending the run with no line.
  # One-shot; a no-op during normal play.
  def maybe_save_test
    return if @save_test_done
    return unless save_test_requested?
    return unless @save_started || current_scene == "Scene_Map"

    unless @save_started
      @save_started = true
      @save_frame = 0
      MV::JS.eval(self.class.save_probe_js(SAVE_PROBE_SLOT))
      $stderr.puts "[MZ] auto save test: slot #{SAVE_PROBE_SLOT}"
      return
    end

    res = MV::JS.eval(self.class.save_result_js)
    res = "" unless res.is_a?(String)
    @save_frame += 1
    if !res.empty?
      @save_test_done = true
      $stderr.puts "[MZ-SAVE] #{res}"
    elsif @save_frame >= SAVE_PROBE_FRAMES
      @save_test_done = true
      $stderr.puts "[MZ-SAVE] the save round-trip never settled " \
                   "(#{SAVE_PROBE_FRAMES} frames)"
    end
  rescue StandardError => e
    $stderr.puts "[MZ] save test error: #{e.message}"
  end

  # The troop id requested by --mz_battle_test (a launcher constant set by
  # main.cxx), or 0 when unset/disabled (e.g. under the test harness). Implies
  # New Game, since the battle is started from the map.
  def battle_test_troop
    v = begin
      MZ_BATTLE_TEST
    rescue StandardError
      0
    end
    troop = v.is_a?(Integer) ? v : 0
    # --mz_battle_play is about the fight, not about which troop it is against,
    # so it implies the entry probe with the first troop unless one was named.
    return 1 if troop.zero? && battle_play_requested?

    troop
  end

  # When --mz_battle_test=<troopId> is set (CI), start a battle against that
  # troop once the map is up (see MZ.battle_probe_js) and log whether
  # `Scene_Battle` was actually reached. This drives the whole combat entry path
  # — the map interpreter's Battle Processing command, `BattleManager.setup`,
  # the encounter effect (which snapshots the map through the WebGL frame
  # extractor for the battle background) and Scene_Battle's own spriteset and
  # windows — so a headless run proves a game can actually get into a fight.
  # One-shot; a no-op otherwise. Mirrors MV#maybe_battle_test.
  def maybe_battle_test
    return if @battle_test_done

    troop = battle_test_troop
    return unless troop > 0

    if @battle_requested
      if current_scene == "Scene_Battle"
        @battle_test_done = true
        $stderr.puts "[MZ-BTL] reached_battle=true"
        return
      end
      @battle_frame += 1
      return if @battle_frame < BATTLE_PROBE_FRAMES

      @battle_test_done = true
      $stderr.puts "[MZ-BTL] reached_battle=false scene=#{current_scene}"
      return
    end

    return unless current_scene == "Scene_Map"

    @battle_requested = true
    @battle_frame = 0
    MV::JS.eval(self.class.battle_probe_js(troop))
    $stderr.puts "[MZ] auto battle test: troop #{troop}"
  rescue StandardError => e
    $stderr.puts "[MZ] battle test error: #{e.message}"
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

  # Frames to let run before capturing — a couple of seconds, enough for the
  # boot to reach a scene and its images to load and draw.
  SHOT_DELAY_FRAMES = 120

  # Extra frames to run after the battle probe reports, before capturing. The
  # probe fires the moment `Scene_Battle` exists, and the scene starts faded
  # out (`startFadeIn`), so shooting on arrival photographs a black screen.
  BATTLE_SHOT_GRACE_FRAMES = 90

  # If a screenshot path was requested (`--mz_screenshot`), write the presented
  # WebGL frame to it once, a couple of seconds in. Used to capture the visual
  # output in CI; a no-op during normal play (no path configured).
  #
  # A battle probe also has to have finished, plus its fade-in: the encounter
  # effect, its flash and `Scene_Battle`'s own fade take longer than the fixed
  # delay, so capturing on frame count alone photographs the fade — a black
  # frame — rather than the battle the run is about. Both waits are bounded (the
  # probe gives up after BATTLE_PROBE_FRAMES), so this cannot wait forever.
  def maybe_screenshot
    return if @shot_taken

    path = begin
      MZ_SCREENSHOT
    rescue StandardError
      ""
    end
    return if path.nil? || path.empty?

    @frames = (@frames || 0) + 1
    return if @frames < SHOT_DELAY_FRAMES
    return if battle_test_troop > 0 && !battle_shot_ready?
    return if animation_test_requested? && !animation_shot_ready?
    return if menu_play_requested? && !menu_play_shot_ready?

    @shot_taken = true
    handle = mz_gl_handle
    ok = handle && handle > 0 && MV::JS.screenshot_gl(path, handle)
    $stderr.puts "[MZ] screenshot #{ok ? "saved" : "failed"}: #{path}"
  rescue StandardError => e
    $stderr.puts "[MZ] screenshot error: #{e.message}"
  end

  # Has the battle probe reported *and* had BATTLE_SHOT_GRACE_FRAMES to fade in?
  # Latches the frame the probe finished on, so the grace period is counted from
  # there rather than from the start of the run.
  def battle_shot_ready?
    return false unless @battle_test_done
    @battle_done_frame ||= @frames
    @frames - @battle_done_frame >= BATTLE_SHOT_GRACE_FRAMES
  end

  # Is this a frame worth photographing for the animation probe? A burst lasts
  # about a fifth of a second and the probe leaves a gap before re-requesting
  # the next one, so the fixed delay on its own photographs the map *between*
  # bursts as often as not. Waiting for cells that are drawing right now puts
  # the animation in the picture. Bounded: once the probe has given up
  # (@anim_test_done) the frame is captured anyway, so a run where nothing ever
  # drew still produces the screenshot that shows it.
  def animation_shot_ready?
    @anim_cells_now || @anim_test_done
  end

  # End the run once every probe that was asked for has reported and the
  # screenshot has been taken, rather than idling until `--timeout_ms`.
  #
  # The two budgets are in different units, and that is the whole problem: a
  # probe gives up after so many *frames*, the engine after so many
  # *milliseconds*. A headless software-GL frame costs far more wall clock on a
  # slow or loaded host than on a fast one, so the same run that reports in half
  # its budget on one machine is cut off mid-probe on another — and a cut-off
  # run prints no report at all, which reads downstream as "the thing under test
  # never happened" rather than "the run ended early". The battle play-out hit
  # exactly this: the fight was landing damage and cycling turns, and the check
  # said no attack ever damaged an enemy.
  #
  # Finishing when the work is done decouples them: `--timeout_ms` can be set
  # generously enough for the slowest host without every run on a fast one
  # taking that long. `RGSS::Timeout` is what the engine itself raises to unwind
  # the loop (see #start), so this ends the run on the same path.
  #
  # Only ever fires when at least one probe was requested — normal play, and
  # Emscripten (which calls #main_loop directly, outside the rescue), never set
  # those flags.
  def finish_when_probes_done
    pending = [
      [move_test_requested?, @move_test_done],
      [transfer_test_requested?, @transfer_test_done],
      [common_event_test_requested?, @common_test_done],
      [message_test_requested?, @msg_test_done],
      [animation_test_requested?, @anim_test_done],
      [menu_test_requested?, @menu_test_done],
      [menu_play_requested?, @menu_play_done],
      [save_test_requested?, @save_test_done],
      [battle_test_troop > 0, @battle_test_done],
      [battle_play_requested?, @btl_play_done],
      [audio_test_requested?, @audio_test_done],
    ]
    requested = pending.select { |asked, _| asked }
    return if requested.empty?
    return unless requested.all? { |_, done| done }
    return if screenshot_requested? && !@shot_taken

    $stderr.puts "[MZ] every probe reported; ending the run"
    raise RGSS::Timeout, "probes finished"
  end

  # Whether a screenshot was asked for (a launcher constant set by main.cxx).
  def screenshot_requested?
    path = begin
      MZ_SCREENSHOT
    rescue StandardError
      ""
    end
    !(path.nil? || path.empty?)
  end

  # Is this a frame worth photographing for the menu play-out? The fixed delay
  # alone lands wherever the walk happens to be — including back on the map, if
  # the setup event is still running — and a map frame proves nothing about the
  # menu. Waiting for the actor window puts the picture at the deepest point of
  # the flow: the item list with the target selection over it, one tap before
  # the item is spent. Bounded the same way the animation's is: once the probe
  # has finished (@menu_play_done) the frame is taken regardless, so a run that
  # never got there still produces the screenshot that shows where it stopped.
  def menu_play_shot_ready?
    @menu_play_at_actor || @menu_play_done
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
