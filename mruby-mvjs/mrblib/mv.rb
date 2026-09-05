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

  # Movement probe (see #maybe_move_test): frames each direction is held, and the
  # total run length. It cycles down/right/up/left so at least one open direction
  # is exercised on any map. Class-level so both the probe and its unit test see
  # them.
  MOVE_PROBE_DWELL = 20
  MOVE_PROBE_FRAMES = 80

  # Settle window before the move probe starts holding a direction (see
  # #maybe_move_test): only paid when $gameMessage is actually busy or
  # $gameMap's own interpreter is still running a page, and the confirm-key
  # tap cadence within it.
  #
  # RGSS's own script-host driver (mruby-rpgxp/mrblib/script_host.rb) taps
  # confirm every CONFIRM_EVERY frames from boot onward and only suppresses it
  # once its move probe starts holding a direction; a real game's autorun
  # opening dialogue (a Show Text/Show Choices sequence that runs the instant
  # the map loads, before the player can act) gets cleared by one of those taps
  # long before the probe needs to walk. MV/MZ's probe had no equivalent: it
  # started holding a direction the instant Scene_Map appeared, so a blocking
  # message window swallowed the input frame after frame and every real game
  # with an opening cutscene reported "did not move" — not because the engine
  # failed to walk the player, but because the probe never got a turn.
  #
  # A fixed-length settle window (paid on every run, dialogue or not) was
  # tried first and reverted: measured against the real data/Lunatic-Core bed
  # under CI's own tight `--timeout_ms=6000` budget, 60 extra frames of
  # confirm-tapping were enough to blow straight through it with zero probe
  # output, because a confirm tap that actually lands on a real game can
  # advance real event logic (more loads, more rendering), not just close an
  # empty window. #message_busy? / #event_running? make the wait conditional
  # instead: a game with no opening event (both false the instant Scene_Map
  # appears) pays nothing and moves exactly as before; MOVE_SETTLE_MAX_FRAMES
  # is only a safety cap on a game that is genuinely still busy.
  #
  # 180 covers an ordinary game's opening dialogue with room to spare, but a
  # real commercial release can script an opening far longer than that: driving
  # data/EgoicAnswers (see docs/TODO.md's M6.3c-area EgoicAnswers entry)
  # through this probe found roughly 650+ frames of blocking waits alone before
  # the player gets a turn, on top of ~49 message boxes and a forced battle —
  # over 3x this cap, by design (it is a title's whole scripted intro, not a
  # dialogue box). Rather than raise the default and make every other run's
  # safety cap that much slower to trip on a genuine hang, .move_settle_max_frames
  # (see below) reads a per-invocation override so a run against a specific
  # long-opening game can ask for more without changing what every other run
  # waits for.
  MOVE_SETTLE_MAX_FRAMES = 180
  CONFIRM_TAP_EVERY = 20
  CONFIRM_TAP_HOLD = 4

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

  # Route MV's audio through RGSS::Audio. MV plays sound via AudioManager, whose
  # browser build decodes files through the Web Audio graph we only stub. Rather
  # than reimplement Web Audio, we override AudioManager's high-level methods to
  # enqueue plain-text ops (tab-separated: op, name, volume, pitch) into
  # __mv_audioQueue; Ruby drains that each frame (`MV#pump_audio`) and calls
  # RGSS::Audio, which is backed by the SDL mixer. `name` is the bare file name
  # MV uses (e.g. "Theme1"); the drain prepends the maker's audio/<kind>/ folder
  # so RGSS resolves it under the game dir. _currentBgm/_currentBgs are kept so
  # AudioManager.saveBgm/saveBgs (used by save/load and map replay) still work.
  AUDIO_BRIDGE_JS = <<~'JS'
    (function (g) {
      if (typeof AudioManager === 'undefined') return;
      var q = g.__mv_audioQueue = [];
      g.__mv_drainAudio = function () { var s = q.join('\n'); q.length = 0; return s; };
      function A(o) { return o || { name: '', volume: 0, pitch: 100, pan: 0 }; }
      AudioManager.playBgm = function (bgm, pos) {
        bgm = A(bgm);
        this._currentBgm = { name: bgm.name, volume: bgm.volume, pitch: bgm.pitch, pan: bgm.pan, pos: pos || 0 };
        q.push(bgm.name ? ('bgm_play\t' + bgm.name + '\t' + bgm.volume + '\t' + bgm.pitch) : 'bgm_stop');
      };
      AudioManager.replayBgm = function (bgm) { this.playBgm(bgm, bgm ? bgm.pos : 0); };
      AudioManager.stopBgm = function () { this._currentBgm = null; q.push('bgm_stop'); };
      AudioManager.fadeOutBgm = function (d) { q.push('bgm_fade\t' + (d || 0)); };
      AudioManager.fadeInBgm = function () {};
      AudioManager.playBgs = function (bgs, pos) {
        bgs = A(bgs);
        this._currentBgs = { name: bgs.name, volume: bgs.volume, pitch: bgs.pitch, pan: bgs.pan, pos: pos || 0 };
        q.push(bgs.name ? ('bgs_play\t' + bgs.name + '\t' + bgs.volume + '\t' + bgs.pitch) : 'bgs_stop');
      };
      AudioManager.replayBgs = function (bgs) { this.playBgs(bgs, bgs ? bgs.pos : 0); };
      AudioManager.stopBgs = function () { this._currentBgs = null; q.push('bgs_stop'); };
      AudioManager.fadeOutBgs = function (d) { q.push('bgs_fade\t' + (d || 0)); };
      AudioManager.fadeInBgs = function () {};
      AudioManager.playMe = function (me) { me = A(me); if (me.name) q.push('me_play\t' + me.name + '\t' + me.volume + '\t' + me.pitch); };
      AudioManager.stopMe = function () { q.push('me_stop'); };
      AudioManager.fadeOutMe = function (d) { q.push('me_fade\t' + (d || 0)); };
      AudioManager.playSe = function (se) { se = A(se); if (se.name) q.push('se_play\t' + se.name + '\t' + se.volume + '\t' + se.pitch); };
      AudioManager.playStaticSe = function (se) { this.playSe(se); };
      AudioManager.stopSe = function () { q.push('se_stop'); };
      AudioManager.stopAll = function () { q.push('all_stop'); };
      AudioManager.checkErrors = function () {};
      AudioManager.updateBgmParameters = function () {};
      AudioManager.updateBgsParameters = function () {};
    })(this);
  JS

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

    # The RGSS::Input direction key the movement probe holds on a given frame.
    # Split out so the cycling is unit-testable without a booted game.
    def move_probe_dir(frame)
      dirs = [RGSS::Input::DOWN, RGSS::Input::RIGHT,
              RGSS::Input::UP, RGSS::Input::LEFT]
      dirs[(frame / MOVE_PROBE_DWELL) % dirs.length]
    end

    # Taps the confirm key (RGSS::Input::C, MV/MZ's "ok") once every
    # CONFIRM_TAP_EVERY frames, held for CONFIRM_TAP_HOLD of them — enough to
    # register as a press through #sync_input without holding it into the next
    # tap's window. `frame` is the caller's own settle-window frame counter
    # (0-based), not the global frame count, so a probe that starts settling
    # later in the run still gets its first tap at the same relative offset.
    def confirm_settle_tap(frame)
      phase = frame % CONFIRM_TAP_EVERY
      RGSS::Input.press(RGSS::Input::C) if phase == 0
      RGSS::Input.release(RGSS::Input::C) if phase == CONFIRM_TAP_HOLD
    end

    # Whether $gameMessage currently holds text a Window_Message is (or is
    # about to be) showing — the same read the message probe uses
    # (#maybe_message_test) to avoid stacking its own message onto a game's.
    # Used by the move probe's settle window to decide whether it has anything
    # to wait out at all. `false` (not busy, or the engine is not up yet)
    # whenever the read itself fails, so a probe never hangs waiting on this.
    def message_busy?
      MV::JS.eval(
        "(typeof $gameMessage !== 'undefined' && $gameMessage && " \
        "$gameMessage.isBusy()) ? true : false"
      ) == true
    rescue StandardError
      false
    end

    # Whether $gameMap's own event interpreter is currently running a page —
    # true for a Show Text/Show Choices sequence (already covered by
    # #message_busy?) but also for one that never touches $gameMessage at all:
    # Show Picture, Wait, Set Move Route, Fadeout/Fadein, Tint Screen and the
    # like. A real game's opening autorun event routinely chains exactly that
    # kind of silent-but-busy sequence before ever showing text, and
    # #message_busy? alone reads `false` throughout it — the move probe's
    # settle window would then never engage and would burn its whole hold
    # budget against a player Game_Player#canMove() is refusing to move,
    # reporting "did not move" for a game the engine never actually failed to
    # walk. `false` (not running, or the engine is not up yet) whenever the
    # read itself fails, matching #message_busy?'s own fail-open shape.
    def event_running?
      MV::JS.eval(
        "(typeof $gameMap !== 'undefined' && $gameMap && " \
        "$gameMap.isEventRunning()) ? true : false"
      ) == true
    rescue StandardError
      false
    end

    # MOVE_SETTLE_MAX_FRAMES, unless a per-run override was requested via the
    # --move_settle_max_frames launcher flag (main.cxx), surfaced here as the
    # MOVE_SETTLE_MAX_FRAMES_OVERRIDE global. 0 (the flag's default, and
    # whatever this reads as before the flag machinery has run at all) means
    # "no override"; a positive value replaces the cap outright. Kept as a
    # method rather than folded into the constant itself so the 180-frame
    # default — sized for an ordinary game's opening dialogue, not a
    # multi-hundred-frame scripted intro — stays the one every other run gets,
    # and only a deliberate per-invocation ask pays for anything larger. See
    # scripts/mz_boot_check.bash's MZ_MOVE_SETTLE_MAX_FRAMES and the
    # EgoicAnswers entry in docs/TODO.md.
    def move_settle_max_frames
      v = begin
        MOVE_SETTLE_MAX_FRAMES_OVERRIDE
      rescue StandardError
        0
      end
      v = v.is_a?(Integer) ? v : 0
      v.positive? ? v : MOVE_SETTLE_MAX_FRAMES
    end

    # JS that pushes a pointer sample (canvas x/y, left-button pressed) into MV's
    # TouchInput: it sets `_x`/`_y` and feeds `_newState` the triggered/released/
    # moved edges MV's DOM handlers would, tracking the previous state on the
    # object so press/release are detected across frames. MV's `TouchInput.update`
    # (run during the scene update) turns `_newState` into the isTriggered/
    # isPressed/isReleased its windows query, so menu clicks work. Split out so
    # the mapping is unit-testable without a live engine or a pointer device.
    def touch_bridge_js(x, y, pressed)
      "(function(x,y,p){ if (typeof TouchInput === 'undefined' || " \
      "!TouchInput._newState) return; TouchInput._x = x; TouchInput._y = y; " \
      "var prev = !!TouchInput.__mvPrev; " \
      "if (p && !prev) { TouchInput._screenPressed = true; " \
      "TouchInput._mousePressed = true; TouchInput._pressedTime = 0; " \
      "TouchInput._newState.triggered = true; } " \
      "else if (!p && prev) { TouchInput._screenPressed = false; " \
      "TouchInput._mousePressed = false; TouchInput._newState.released = true; } " \
      "else if (p && prev) { TouchInput._newState.moved = true; } " \
      "TouchInput.__mvPrev = p; })(#{x.to_i}, #{y.to_i}, " \
      "#{pressed ? "true" : "false"});"
    end

    # Parse one drained audio op (see AUDIO_BRIDGE_JS) into a call spec:
    # [method, *args]. `*_play` ops become [:kind_play, "audio/<kind>/<name>",
    # volume, pitch] with the maker's folder prepended so RGSS resolves it under
    # the game dir; stops/fades/all_stop map to their RGSS::Audio equivalents.
    # Returns nil for an empty or unknown op. Split out so the mapping is
    # unit-testable without a live engine or audio device.
    def parse_audio_op(line)
      p = line.split("\t")
      case p[0]
      when "bgm_play" then [:bgm_play, "audio/bgm/#{p[1]}", p[2].to_f, p[3].to_f]
      when "bgs_play" then [:bgs_play, "audio/bgs/#{p[1]}", p[2].to_f, p[3].to_f]
      when "me_play" then [:me_play, "audio/me/#{p[1]}", p[2].to_f, p[3].to_f]
      when "se_play" then [:se_play, "audio/se/#{p[1]}", p[2].to_f, p[3].to_f]
      when "bgm_stop" then [:bgm_stop]
      when "bgs_stop" then [:bgs_stop]
      when "me_stop" then [:me_stop]
      when "se_stop" then [:se_stop]
      when "bgm_fade" then [:bgm_fade, (p[1].to_f * 1000).to_i]
      when "bgs_fade" then [:bgs_fade, (p[1].to_f * 1000).to_i]
      when "me_fade" then [:me_fade, (p[1].to_f * 1000).to_i]
      when "all_stop" then [:all_stop]
      end
    end

    # Dispatch a parsed audio call (see .parse_audio_op) to RGSS::Audio. A class
    # method because MZ drives the same bridge: rmmz's AudioManager exposes the
    # same high-level surface AUDIO_BRIDGE_JS overrides, so both runtimes queue
    # identical ops and both drain them through here.
    def apply_audio_op(call)
      case call[0]
      when :bgm_play then RGSS::Audio.bgm_play(call[1], call[2], call[3])
      when :bgs_play then RGSS::Audio.bgs_play(call[1], call[2], call[3])
      when :me_play then RGSS::Audio.me_play(call[1], call[2], call[3])
      when :se_play then RGSS::Audio.se_play(call[1], call[2], call[3])
      when :bgm_stop then RGSS::Audio.bgm_stop
      when :bgs_stop then RGSS::Audio.bgs_stop
      when :me_stop then RGSS::Audio.me_stop
      when :se_stop then RGSS::Audio.se_stop
      when :bgm_fade then RGSS::Audio.bgm_fade(call[1])
      when :bgs_fade then RGSS::Audio.bgs_fade(call[1])
      when :me_fade then RGSS::Audio.me_fade(call[1])
      when :all_stop
        RGSS::Audio.bgm_stop
        RGSS::Audio.bgs_stop
        RGSS::Audio.me_stop
        RGSS::Audio.se_stop
      end
    end

    # Reads `<game_dir>/data/System.json`'s `hasEncryptedAudio`/
    # `encryptionKey` (the same fields the corescript's own `Decrypter`/
    # `Bitmap._startDecrypting` read for *images*) and, if set, arms
    # RGSS::Audio's loose-encrypted-file fallback
    # (mruby-rgss/mrblib/lib.rb's ENCRYPTED_EXTS/#find_encrypted_loose) with
    # the raw 16-byte key. A class method, not an instance one, because MZ
    # drives the identical audio bridge from its own class (see .apply_audio_op
    # above) and calls this the same way, right after installing it
    # (mrblib/mz.rb's #boot_probe).
    #
    # Images need no equivalent call: AUDIO_BRIDGE_JS only overrides
    # AudioManager, so an encrypted image still takes the corescript's own
    # decrypt-in-JS route (XHR arraybuffer -> Decrypter.decryptImg -> Blob ->
    # Image), which this project's host globals already support end to end (see
    # ADR 0004 M6.3r). Audio is different *because* AUDIO_BRIDGE_JS exists:
    # AudioManager.playBgm/playSe are overridden to bypass MZ's WebAudio (whose
    # `fetch` this host leaves inert, see docs/TODO.md's M6.3c "Audio") and
    # queue a plain asset name for RGSS::Audio to play by filename instead --
    # which never runs the corescript's own decrypt step. Found against a real
    # downloaded MZ release (EgoicAnswers, hasEncryptedAudio) whose every BGM/SE
    # logged "Audio: no BGM/SE found" even though e.g.
    # audio/bgm/mozegaku4_04_komorebi.ogg_ is right there on disk -- RGSS::Audio
    # was (correctly) never taught to look for a `.ogg_`/`.rpgmvo` sibling, let
    # alone decrypt one.
    #
    # A project with no encrypted audio (the common case, including every
    # RPG2000/XP/VX/Ace bed, which knows nothing of this flag at all) reads a
    # `false`/absent flag and leaves RGSS::Audio.encryption_key at its `nil`
    # default -- zero behaviour change.
    def maybe_enable_audio_decryption(game_dir)
      path = "#{game_dir}/data/System.json"
      return unless File.file?(path)

      json = File.open(path, "r") { |f| f.read }
      return if json.scan(/"hasEncryptedAudio"\s*:\s*true/).empty?

      key_hex = json.scan(/"encryptionKey"\s*:\s*"([0-9a-fA-F]{32})"/).flatten.first
      return unless key_hex

      RGSS::Audio.encryption_key = key_hex.scan(/../).map { |b| b.to_i(16) }
    rescue StandardError => e
      $stderr.puts "[MV] error reading audio encryption key: #{e.message}"
    end

    # Reads `<game_dir>/data/System.json`'s `advanced.mainFontFilename` and
    # tells game_font() (mvcanvas.cxx, via MV::Font.preferred_filename=) to
    # load exactly that file rather than guessing from whichever extension
    # `readdir()` happens to see first. Called only from MZ's own boot path
    # (mz.rb) -- MV's System.json has no such field, and unlike
    # #maybe_enable_audio_decryption just above (which both makers call,
    # since encrypted audio is a real MV feature too), MV's own boot never
    # calls this at all; a missing/empty field is a silent no-op here
    # regardless (any MZ project shipping only one font, or an older
    # System.json predating this key), not an error. Same read style as
    # #maybe_enable_audio_decryption (a plain regex scan over the raw JSON,
    # not a parse) and the same reason: one specific string field, not a
    # reason to add a JSON dependency to this translation unit.
    #
    # Matters once a project ships more than one font file: real MZ projects
    # commonly name a *second*, separately-subsetted `advanced.numberFontFilename`
    # for battle damage digits (see mv_font_set_preferred_filename's own
    # comment, mvhost.hxx, for the real downloaded release this was found
    # against and exactly how wrong the result was). A project shipping one
    # font -- every test bed so far -- has nothing to disambiguate and this is
    # a no-op either way.
    def maybe_set_main_font(game_dir)
      path = "#{game_dir}/data/System.json"
      return unless File.file?(path)

      json = File.open(path, "r") { |f| f.read }
      name = json.scan(/"mainFontFilename"\s*:\s*"([^"]*)"/).flatten.first
      return if name.nil? || name.empty?

      MV::Font.preferred_filename = name
    rescue StandardError => e
      $stderr.puts "[MV] error reading main font filename: #{e.message}"
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

    # Under Emscripten the browser calls main_loop directly without going through
    # #start, so boot the game lazily on the first frame. Native runs boot via
    # #start, which sets @booted, so this is a no-op there.
    boot unless @booted

    sync_input # M5: push RGSS input into MV's Input before the scene updates
    sync_touch # M5: push RGSS mouse into MV's TouchInput before the scene update
    pump_frame # M3: run the rAF/timer queue for one frame
    pump_audio # M5: drain MV's queued audio ops into RGSS::Audio
    log_scene_transition # trace boot progress (Scene_Boot -> Scene_Title -> ...)
    maybe_new_game # CI: auto-advance past the title to the first map
    maybe_battle_test # CI: start a test battle once on the map, if requested
    maybe_move_test # CI: hold a direction on the map and log that the player moved
    maybe_message_test # CI: show a text message on the map and log the window opened
    maybe_menu_test # CI: open the menu on the map and log that Scene_Menu opened
    maybe_save_test # CI: save+load round-trip on the map and log the result
    maybe_audio_test # CI: play an SE through the bridge and log it dispatched
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

  # Bridge the pointer to MV's TouchInput (menu/title clicking). RGSS::Input,
  # fed by the SDL backend, exposes the current pointer position and button;
  # push a sample into TouchInput each frame before the scene updates (see
  # MV.touch_bridge_js). No-op until the engine (and thus TouchInput) has loaded,
  # and inert under backends with no mouse (the state stays at the origin,
  # unpressed).
  def sync_touch
    MV::JS.eval(
      self.class.touch_bridge_js(
        RGSS::Input.mouse_x, RGSS::Input.mouse_y, RGSS::Input.mouse_pressed?
      )
    )
  rescue StandardError => e
    $stderr.puts "[MV] touch sync error: #{e.message}"
  end

  # Drain the audio ops MV queued this frame (see AUDIO_BRIDGE_JS) and play them
  # through RGSS::Audio. No-op until the bridge is installed (post-boot) and
  # while nothing is queued.
  def pump_audio
    data = MV::JS.eval(
      "(typeof __mv_drainAudio === 'function') ? __mv_drainAudio() : ''"
    )
    return unless data.is_a?(String) && !data.empty?

    data.split("\n").each do |line|
      next if line.empty?
      call = self.class.parse_audio_op(line)
      apply_audio(call) if call
    end
  rescue StandardError => e
    $stderr.puts "[MV] audio error: #{e.message}"
  end

  # Dispatch a parsed audio call (see MV.parse_audio_op) to RGSS::Audio.
  def apply_audio(call)
    self.class.apply_audio_op(call)
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

  # The running scene's class name, or "" if none yet.
  def current_scene
    MV::JS.eval(
      "(typeof SceneManager !== 'undefined' && SceneManager._scene) ? " \
      "SceneManager._scene.constructor.name : ''"
    )
  rescue StandardError
    ""
  end

  # When --mv_new_game is set (CI) — or a battle test is requested, which needs
  # to reach the map first — select "New Game" once the title screen is up so
  # the game advances to its first map without any input, letting a headless
  # capture show in-game rendering, not just the title. One-shot; a no-op during
  # normal play (flags unset).
  def maybe_new_game
    return if @new_game_done
    new_game = begin
      MV_NEW_GAME
    rescue StandardError
      false
    end
    return unless new_game || battle_test_troop > 0 || move_test_requested? ||
                  message_test_requested? || menu_test_requested? ||
                  save_test_requested? || audio_test_requested?
    return unless current_scene == "Scene_Title"

    @new_game_done = true
    MV::JS.eval(
      "if (SceneManager._scene && SceneManager._scene.commandNewGame) " \
      "SceneManager._scene.commandNewGame();"
    )
    $stderr.puts "[MV] auto New Game"
  rescue StandardError => e
    $stderr.puts "[MV] new game error: #{e.message}"
  end

  # How many frames to keep watching for Scene_Battle after requesting it before
  # giving up and logging a failure — generous, since New Game's fade, the map
  # settle, the encounter-effect intro (~60f) and Scene_Battle's fade-in all
  # have to play out first, and headless frames are slower than 60fps.
  BATTLE_PROBE_FRAMES = 120

  # When --mv_battle_test=<troopId> is set (CI), start a test battle against that
  # troop once the map is up, so a headless capture shows Scene_Battle (its
  # windows, HP/MP gauges and battler layout), then log whether it was actually
  # reached. One-shot; a no-op otherwise.
  #
  # The battle is started the way a real game does — a "Battle Processing" event
  # command (code 301) run through the *map interpreter* — NOT a bare
  # `SceneManager.push(Scene_Battle)` injected from outside the scene loop. The
  # bare push deadlocks: `Scene_Map.stop` kicks off the encounter-effect intro,
  # but that intro only advances while the scene is inactive, and an
  # out-of-loop push leaves the map active with the effect frozen, so the
  # pending Scene_Battle never applies. Running 301 inside Scene_Map's own
  # update (via the interpreter) is the path the engine itself uses and it
  # transitions cleanly.
  def maybe_battle_test
    return if @battle_test_done

    troop = battle_test_troop
    return unless troop > 0

    # After the request, watch for the transition: report as soon as
    # Scene_Battle is up (the intro can take longer than a fixed wait under a
    # slow headless framerate), and give up with a failure line only if it never
    # arrives within the probe window.
    if @battle_requested
      if current_scene == "Scene_Battle"
        @battle_test_done = true
        $stderr.puts "[MV-BTL] reached_battle=true"
        return
      end
      @battle_frame += 1
      return if @battle_frame < BATTLE_PROBE_FRAMES

      @battle_test_done = true
      $stderr.puts "[MV-BTL] reached_battle=false scene=#{current_scene}"
      return
    end

    return unless current_scene == "Scene_Map"

    @battle_requested = true
    @battle_frame = 0
    MV::JS.eval(
      "if ($gameMap && $gameMap._interpreter) { $gameMap._interpreter.setup(" \
      "[{code:301,indent:0,parameters:[0,#{troop},true,false]}," \
      "{code:0,indent:0,parameters:[]}], 0); }"
    )
    $stderr.puts "[MV] auto battle test: troop #{troop}"
  rescue StandardError => e
    $stderr.puts "[MV] battle test error: #{e.message}"
  end

  # The troop id requested by --mv_battle_test (a launcher constant set by
  # main.cxx), or 0 when unset/disabled (e.g. under the test harness).
  def battle_test_troop
    v = begin
      MV_BATTLE_TEST
    rescue StandardError
      0
    end
    v.is_a?(Integer) ? v : 0
  end

  # Whether --mv_move_test was requested (a launcher constant set by main.cxx).
  def move_test_requested?
    (begin
      MV_MOVE_TEST
    rescue StandardError
      false
    end) == true
  end

  # The player's current map tile as "x,y", or "" if the game isn't up yet.
  def player_tile
    MV::JS.eval("($gamePlayer ? ($gamePlayer.x + ',' + $gamePlayer.y) : '')")
  rescue StandardError
    ""
  end

  # When --mv_move_test is set (CI), once on the map hold a direction — cycling
  # so some open direction is found — via RGSS::Input for MOVE_PROBE_FRAMES
  # frames, then log the player's start/end tile and whether it ever moved. This
  # drives the full path (RGSS::Input -> sync_input -> MV Input -> Scene_Map ->
  # Game_Player -> Game_Map passability -> position), so a headless run confirms
  # input actually walks the player, not just that the map renders. The input is
  # pushed into MV by next frame's #sync_input. One-shot; a no-op during normal
  # play (flag unset).
  #
  # Before any direction is held, the probe checks whether $gameMessage is
  # already busy or $gameMap's own interpreter is running a page (see
  # .message_busy? / .event_running?): a real game's opening autorun event can
  # run a Show Text/Show Choices sequence the instant the map loads, and a
  # blocking message window swallows movement input frame after frame — or it
  # can run Show Picture/Wait/Move Route/Fadeout steps that never touch
  # $gameMessage at all, which #message_busy? alone can't see. Either way the
  # probe would report "did not move" not because the engine failed to walk
  # the player, but because it never got a turn against the game's own event.
  # If either is true, confirm gets tapped (see .confirm_settle_tap) until
  # both clear or .move_settle_max_frames runs out (MOVE_SETTLE_MAX_FRAMES, or
  # the --move_settle_max_frames override — see that method); if neither was
  # busy to begin with, movement starts immediately, exactly as before this existed.
  # If the interpreter is *still* running once the probe ends, the "end" line
  # says so (`blocked=true`) rather than reporting a bare `moved=false`
  # indistinguishable from a real movement bug — see the note at the bottom of
  # this method.
  def maybe_move_test
    return if @move_test_done
    return unless move_test_requested?
    return unless current_scene == "Scene_Map"

    unless @move_settled
      @move_settle_frame ||= 0
      if (self.class.message_busy? || self.class.event_running?) &&
         @move_settle_frame < self.class.move_settle_max_frames
        self.class.confirm_settle_tap(@move_settle_frame)
        @move_settle_frame += 1
        return
      end
      RGSS::Input.release(RGSS::Input::C)
      @move_settled = true
    end

    @move_frame ||= 0
    if @move_frame.zero?
      @move_start = player_tile
      $stderr.puts "[MV-MOVE] start #{@move_start}"
    end
    cur = player_tile
    @move_seen = true if !cur.empty? && cur != @move_start

    dirs = [RGSS::Input::UP, RGSS::Input::DOWN, RGSS::Input::LEFT,
            RGSS::Input::RIGHT]
    dirs.each { |k| RGSS::Input.release(k) }
    @move_frame += 1
    if @move_frame < MOVE_PROBE_FRAMES
      RGSS::Input.press(self.class.move_probe_dir(@move_frame))
      return
    end

    @move_test_done = true
    blocked = self.class.event_running?
    $stderr.puts "[MV-MOVE] end #{player_tile} " \
                 "moved=#{@move_seen ? true : false} blocked=#{blocked}"
  rescue StandardError => e
    $stderr.puts "[MV] move test error: #{e.message}"
  end

  # Whether --mv_message_test was requested (a launcher constant set by main.cxx).
  def message_test_requested?
    (begin
      MV_MESSAGE_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mv_message_test is set (CI), once on the map queue a "Show Text"
  # message through $gameMessage, let Scene_Map's Window_Message open and draw
  # it over a few frames, then log whether the window opened and is showing the
  # text. This drives the message/dialogue path every RPG uses (event ->
  # $gameMessage -> Window_Message -> text render), so a headless run confirms
  # message boxes actually display. One-shot; a no-op during normal play.
  MSG_PROBE_FRAMES = 45
  def maybe_message_test
    return if @msg_test_done
    return unless message_test_requested?
    return unless current_scene == "Scene_Map"

    @msg_frame ||= 0
    if @msg_frame == 0
      MV::JS.eval(
        "if (typeof $gameMessage !== 'undefined' && !$gameMessage.isBusy()) " \
        "{ $gameMessage.add('MV message smoke test'); }"
      )
      $stderr.puts "[MV-MSG] queued a message"
    end
    @msg_frame += 1
    return if @msg_frame < MSG_PROBE_FRAMES

    @msg_test_done = true
    busy = MV::JS.eval("(typeof $gameMessage !== 'undefined' && " \
                       "$gameMessage.isBusy()) ? true : false")
    open = MV::JS.eval(
      "(SceneManager._scene && SceneManager._scene._messageWindow && " \
      "SceneManager._scene._messageWindow.openness > 0) ? true : false"
    )
    $stderr.puts "[MV-MSG] busy=#{busy} window_open=#{open}"
  rescue StandardError => e
    $stderr.puts "[MV] message test error: #{e.message}"
  end

  # Whether --mv_menu_test was requested (a launcher constant set by main.cxx).
  def menu_test_requested?
    (begin
      MV_MENU_TEST
    rescue StandardError
      false
    end) == true
  end

  # Frames to keep watching for Scene_Menu after requesting it before giving up.
  MENU_PROBE_FRAMES = 60

  # When --mv_menu_test is set (CI), once on the map open the party menu the way
  # the engine does — set Scene_Map's own `menuCalling` flag and let its
  # `updateCallMenu` run `callMenu` (SoundManager.playOk + push Scene_Menu)
  # inside the scene loop — then log whether Scene_Menu actually opened. This
  # drives the menu path every RPG uses (map -> Scene_Menu -> the command /
  # status windows), so a headless run confirms the menu opens. We flip the
  # scene's flag rather than press a key because MV's keyboard keyMapper has no
  # 'menu' binding (only the gamepad Y); `menuCalling` is exactly what
  # `isMenuCalled` sets, so this takes the real callMenu path.
  #
  # The flag is re-asserted every frame, not set once: `updateCallMenu` clears
  # `menuCalling` on any frame the menu is momentarily disabled (an autorun or
  # the New Game transfer still settling right after reaching the map), so a
  # single set can be dropped before it ever fires. One-shot report.
  def maybe_menu_test
    return if @menu_test_done
    return unless menu_test_requested?
    return unless @menu_requested || current_scene == "Scene_Map"

    if current_scene == "Scene_Menu"
      @menu_test_done = true
      $stderr.puts "[MV-MENU] reached_menu=true"
      return
    end

    @menu_frame ||= 0
    $stderr.puts "[MV] auto menu test" if @menu_frame == 0
    @menu_frame += 1

    # (Re)assert the menu call this frame; Scene_Map's updateCallMenu runs
    # callMenu once the menu is enabled and the player is not moving.
    @menu_requested = true
    MV::JS.eval(
      "if (SceneManager._scene && " \
      "SceneManager._scene.constructor.name === 'Scene_Map') { " \
      "SceneManager._scene.menuCalling = true; }"
    )
    return if @menu_frame < MENU_PROBE_FRAMES

    @menu_test_done = true
    $stderr.puts "[MV-MENU] reached_menu=false scene=#{current_scene}"
  rescue StandardError => e
    $stderr.puts "[MV] menu test error: #{e.message}"
  end

  # Whether --mv_save_test was requested (a launcher constant set by main.cxx).
  def save_test_requested?
    (begin
      MV_SAVE_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mv_save_test is set (CI), once on the map run a save+load round-trip
  # through the real DataManager and log the result. This drives the save path
  # every game relies on: DataManager.saveGame serializes $game* into a save
  # slot via StorageManager (our host keeps Utils.isNwjs() false, so this goes
  # through the localStorage shim that persists to disk), StorageManager.exists
  # confirms the slot, and DataManager.loadGame reads it back and rebuilds the
  # game objects. A headless run thus confirms saves actually write and reload.
  # One-shot; a no-op during normal play (flag unset).
  def maybe_save_test
    return if @save_test_done
    return unless save_test_requested?
    return unless current_scene == "Scene_Map"

    @save_test_done = true
    res = MV::JS.eval(
      "(function(){ try { " \
      "if (typeof DataManager === 'undefined') return 'no DataManager'; " \
      "var saved = DataManager.saveGame(1); " \
      "var exists = StorageManager.exists(1); " \
      "var loaded = DataManager.loadGame(1); " \
      "return 'saved=' + (!!saved) + ' exists=' + (!!exists) + " \
      "' loaded=' + (!!loaded); " \
      "} catch (e) { return 'error: ' + String(e && e.message || e); } })()"
    )
    $stderr.puts "[MV-SAVE] #{res}"
  rescue StandardError => e
    $stderr.puts "[MV] save test error: #{e.message}"
  end

  # Whether --mv_audio_test was requested (a launcher constant set by main.cxx).
  def audio_test_requested?
    (begin
      MV_AUDIO_TEST
    rescue StandardError
      false
    end) == true
  end

  # When --mv_audio_test is set (CI), once on the map play a sound effect
  # through MV's AudioManager and drive it the whole way to RGSS::Audio, then
  # log the result. Our bridge (AUDIO_BRIDGE_JS) overrides AudioManager to
  # enqueue a plain-text op instead of decoding Web Audio; here we play the
  # sample's authored "Beep" SE, drain the op the live engine queued (proving
  # AudioManager -> __mv_audioQueue works with a real game), parse it and
  # dispatch through the same #apply_audio the per-frame #pump_audio uses, and
  # confirm the asset resolves on disk. So a headless run exercises the full
  # audio path (engine -> queue -> drain -> RGSS::Audio) end to end, which the
  # empty-audio test beds never did. One-shot; a no-op during normal play.
  def maybe_audio_test
    return if @audio_test_done
    return unless audio_test_requested?
    return unless current_scene == "Scene_Map"

    @audio_test_done = true
    op = MV::JS.eval(
      "(function(){ if (typeof AudioManager === 'undefined') return ''; " \
      "AudioManager.playSe({ name: 'Beep', volume: 90, pitch: 100, pan: 0 }); " \
      "return (typeof __mv_drainAudio === 'function') ? __mv_drainAudio() : " \
      "''; })()"
    )
    line = op.is_a?(String) ? op.split("\n").first.to_s : ""
    call = self.class.parse_audio_op(line)
    apply_audio(call) if call
    asset = File.exist?("#{@game_dir}/audio/se/Beep.wav")
    $stderr.puts "[MV-AUDIO] op=#{line.inspect} dispatched=#{!call.nil?} " \
                 "asset=#{asset}"
  rescue StandardError => e
    $stderr.puts "[MV] audio test error: #{e.message}"
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
    @booted = true # guard so the lazy boot in #main_loop runs only once
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
    # Route MV's audio (AudioManager) through RGSS::Audio instead of the stubbed
    # Web Audio graph. Installed now that rpg_managers.js (AudioManager) is
    # loaded; the per-frame drain in main_loop plays what MV queues.
    MV::JS.eval(AUDIO_BRIDGE_JS)
    self.class.maybe_enable_audio_decryption(@game_dir)

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
