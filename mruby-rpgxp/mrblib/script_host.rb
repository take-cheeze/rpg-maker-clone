# RGSS script host — the "run the bundled scripts" path.
#
# An RPG Maker XP project ships its whole engine (title, map, event interpreter,
# menus, battle, …) as ~90 Ruby scripts inside Data/Scripts.rxdata. The native
# player, RGSS104E.dll, boots a game simply by evaluating those sections in order
# at the top level: the value types, Graphics/Input/Audio and the RPG data
# classes are provided by the DLL, and the final "Main" section runs the game
# loop (`$scene.main while $scene != nil`).
#
# This module is the mruby equivalent of that: given the project database it
# exposes the handful of Kernel built-ins the scripts expect the engine to
# supply (load_data / save_data / $RGSS_SCRIPTS), then evals each decompressed
# section against the top level using its editor name — so the game's own logic
# runs unmodified.
#
# It was built as the alternative to a reimplementation of RMXP's default engine
# (docs/adr/0017-rpgxp-rgss-script-host.md), became the default boot path
# (ADR 0029), and is now the **only** one: ADR 0030 removed the reimplementation,
# because reproducing the default scripts could never run the games that
# customise them. A project that ships no scripts has nothing to run, and the
# boot shell says so.
# `Kernel#eval` comes from the core mruby-eval gem, a hard dependency of this gem
# (mruby-rpgxp/mrbgem.rake).
class RPGXP
  # Defined with explicit `def self.` singleton methods (not a bare
  # `module_function`, which this mruby build does not apply to later defs) so
  # the host is callable as RPGXP::ScriptHost.<method>.
  module ScriptHost
    # Environment variable that switches the script host off. The host is on by
    # default, so this is an *opt-out*: set RGSS_SCRIPT_HOST to one of
    # DISABLED_VALUES and the project is loaded but not run — there is no second
    # engine to run it with (ADR 0030), so this is a way to inspect a project, or
    # to boot past scripts that crash the engine, not a way to play one. The
    # native binary spells the same switch --norgss_script_host.
    ENABLED_ENV = "RGSS_SCRIPT_HOST".freeze

    # The values that turn the host *off*, compared literally in lower case (no
    # String#downcase, which this mruby build is not known to carry — the same
    # reason the rest of this gem sticks to the common subset). Anything else —
    # including "1" — leaves the host on. src/main.cxx carries the same list for
    # the environment variable it reads on the Ruby side's behalf; keep them
    # together.
    DISABLED_VALUES = ["0", "false", "off", "no"].freeze

    # True while the host's blocking `Main` runs inside the driver Fiber (see
    # RPGXP#setup_script_host_driver). The wrapped Graphics.update reads this to
    # decide whether to yield the fiber once per frame — so the flag is only ever
    # set while a game is being driven, and nothing else yields. See
    # docs/adr/0023-rpgxp-script-host-frame-driver.md.
    @driving = false
    def self.driving?
      @driving
    end

    def self.driving=(v)
      @driving = v
    end

    # Whether to run the project's bundled scripts. **On by default**, and the
    # only way a game runs: an RGSS project's scripts *are* its engine (ADR
    # 0030). Only an explicit opt-out turns it off, from either of two places,
    # because the two runtimes read their settings differently:
    #
    # **The `--rgss_script_host` flag** is the switch that works in a built
    # engine. src/main.cxx publishes it as the RGSS_SCRIPT_HOST constant, the way
    # it publishes the other headless-run switches, and it is read through its own
    # rescue because an undefined constant raises here (this mruby has no
    # `defined?(CONST)`). It also folds in the environment variable below, which a
    # booted game cannot read for itself.
    #
    # **The RGSS_SCRIPT_HOST environment variable** is what every document used
    # to name, and on its own it could never have switched the host: this mruby
    # build has no ENV at all, so the check below was simply never reached in the
    # engine. Only the CRuby harnesses — where ENV does exist — ever saw it work,
    # which is why the dead switch went unnoticed. It is still honoured, for them.
    #
    # With neither present — an embedded target, or a host-side unit test — the
    # default stands.
    def self.enabled?
      setting = flag_setting
      return setting unless setting.nil?
      return true unless Object.const_defined?(:ENV)
      flag = ENV[ENABLED_ENV]
      # Unset or empty is "not asked for either way" — the default wins.
      return true if flag.nil? || flag.empty?
      !DISABLED_VALUES.include?(flag)
    end

    # The RGSS_SCRIPT_HOST constant the native binary publishes, or nil where
    # there is none (the CRuby harnesses, mrbtest, an embedded build) — nil is
    # "nothing said", which is why this cannot just answer true/false.
    def self.flag_setting
      RGSS_SCRIPT_HOST
    rescue StandardError
      nil
    end

    # Run the project's bundled scripts to completion. `db` answers #scripts
    # (an ordered array of [name, source]) and #read_object / #save_object for
    # the Kernel built-ins. Returns true when the scripts were run, false when
    # the project ships none, which the caller reports.
    # Evaluating "Main" blocks here until the game's own loop exits, exactly as
    # RGSS does.
    def self.run(db)
      sections = db.scripts
      if sections.empty?
        $stderr.puts "[RGSS] script host: project ships no scripts"
        return false
      end
      install_kernel(db)
      seed_random
      # RGSS exposes the loaded sections as $RGSS_SCRIPTS ([id, name, source]);
      # some scripts read it (e.g. to hot-reload). Mirror that shape.
      idx = -1
      $RGSS_SCRIPTS = sections.map { |name, source| [idx += 1, name, source] }
      # A machine-readable marker: what a headless run
      # (scripts/rpgxp_boot_check.bash) asserts on to prove a game's own bundle is
      # what booted, and how much of it there was.
      $stderr.puts "[RPGXP-SCRIPTS] running #{sections.size} script sections"
      sections.each do |name, source|
        # Evaluate through the top-level helper so a section's `class Scene_Title`
        # etc. define global (::) constants, as under RGSS — see rgss_eval_section.
        #
        # Name the section in the failure. The host is how a game's own engine
        # runs, so a boot failure is a report about which part of the RGSS class
        # library is still missing (docs/rpgxp-rgss-api-gap.md) — and "NameError:
        # uninitialized constant RPG::Sprite" says nothing about *where* to look
        # without it. Re-raised, so the run ends on it.
        begin
          rgss_eval_section(source, name)
        rescue StandardError, ScriptError => e
          # A timeout is how a *headless* run ends, not how it fails: the driver
          # treats it as a clean end (RPGXP#drive_script_host). Reporting it as
          # "section Main raised …" with a backtrace made a passing CI run read
          # like a crashed one.
          raise e if quiet_end?(e)
          $stderr.puts "[RGSS] script host: section #{name.inspect} raised " \
                       "#{e.class}: #{e.message}"
          report_backtrace(e)
          # `raise` with no argument loses the exception in this mruby build
          # (the caller saw a bare RuntimeError), so re-raise it explicitly.
          raise e
        end
      end
      true
    end

    # Pin the random number generator, when a headless run asked for it.
    #
    # mruby seeds from the clock and a game's own engine rolls constantly — the
    # encounter count as the party is placed, damage variance, and the order the
    # battlers act in — so two runs of the same check drive two different games.
    # That is fine for a player and useless for a check: the battle probe passed
    # twice and then failed inside the game's own `make_action_orders`, and there
    # was no way to ask for that run back.
    #
    # Seeded here rather than in the native boot because this is the last moment
    # before the game's own code runs, so nothing of ours can consume a value
    # first and shift every roll the game makes.
    def self.seed_random
      seed = random_seed
      return if seed.nil? || seed.zero?
      $stderr.puts "[RPGXP-SCRIPTS] random seed #{seed}"
      srand(seed)
    rescue StandardError
      # An mruby without Kernel#srand would be a build without mruby-random,
      # which a game cannot run anyway; it is not this method's job to say so.
      nil
    end

    # `--rgss_random_seed`, published by src/main.cxx. 0 (and the absent
    # constant, under the CRuby harnesses) means "leave the clock seed alone".
    def self.random_seed
      RGSS_RANDOM_SEED
    rescue StandardError
      nil
    end

    # Whether this exception is the run *ending* rather than the game breaking.
    # Only the timeout qualifies here: `exit` raises SystemExit, which is not a
    # StandardError and never reaches the rescue above. Guarded, because the
    # CRuby harnesses load this file without RGSS::Timeout defined.
    def self.quiet_end?(e)
      RGSS.const_defined?(:Timeout) && e.is_a?(RGSS::Timeout)
    rescue StandardError
      false
    end

    # Where in the *game's own scripts* a failure happened. The section name and
    # exception alone say what is missing but not where — and once a game is past
    # its title screen, "Main raised NoMethodError" can mean any of a hundred
    # scripts. Each section is evaluated under its editor name (rgss_eval_section
    # passes it to eval), so the frames read like `Game_Battler_1:61`, which is
    # the line to open in the editor. Best effort: an mruby build without
    # backtraces just prints nothing extra.
    BACKTRACE_FRAMES = 12

    def self.report_backtrace(e)
      return unless e.respond_to?(:backtrace)
      frames = e.backtrace
      return if frames.nil? || frames.empty?
      frames.first(BACKTRACE_FRAMES).each do |frame|
        $stderr.puts "[RGSS] script host:   from #{frame}"
      end
      dropped = frames.size - BACKTRACE_FRAMES
      $stderr.puts "[RGSS] script host:   ... #{dropped} more" if dropped > 0
    rescue StandardError
      # A backtrace is a diagnostic, never a second failure.
      nil
    end

    # The database the Kernel built-ins (Object#load_data / #save_data, defined
    # below) read and write through. Point it at the running project's database.
    def self.db
      @db
    end

    def self.install_kernel(db)
      @db = db
    end

    # Build the per-frame driver Fiber for a project's bundled scripts. The
    # scripts own their whole blocking main loop, so it runs inside a Fiber that
    # the wrapped Graphics.update below yields once per frame — the caller then
    # resumes it once per frame (see RPGXP#drive_script_host / RPGVX). Shared by
    # every RGSS maker's boot shell; see
    # docs/adr/0023-rpgxp-script-host-frame-driver.md.
    def self.build_driver(db)
      install_graphics_yield
      Fiber.new do
        self.driving = true
        begin
          run(db)
        ensure
          self.driving = false
        end
      end
    end

    # Wrap the native Graphics.update so a scene's `loop { Graphics.update; ... }`
    # yields the driver Fiber once per frame. Idempotent, and installed only when
    # a game is actually driven, so a project with no scripts never wraps it.
    def self.install_graphics_yield
      return if RGSS::Graphics.respond_to?(:_update_native)
      RGSS::Graphics.singleton_class.class_eval do
        alias_method :_update_native, :update
        def update
          _update_native
          return unless ::RPGXP::ScriptHost.driving?
          ::RPGXP::ScriptHost.watch_frame
          Fiber.yield
        end
      end
    end

    # Frames the host has driven, the last scene it reported, and the frame the
    # game's own map scene first appeared on (which is when the move probe can
    # start).
    @frames = 0
    @scene_name = nil
    @map_frame = nil

    # The game's own idea of "what scene is up", across two different real
    # conventions this engine's three RGSS variants use. XP and VX (RGSS/RGSS2)
    # run `$scene.main while $scene`, a plain global `Main` assigns and reads
    # directly. VX Ace (RGSS3) replaced that with `SceneManager` (`Main` calls
    # `SceneManager.run`, which loops `SceneManager.scene.main`) and its stock
    # scripts never touch `$scene` at all -- confirmed against a real VX Ace
    # release's full 213-section bundle: zero `$scene =` assignments, every
    # scene class threaded through `SceneManager` instead. Every probe below
    # used to key on `$scene` alone, so on a real VX Ace game it stayed nil
    # forever: `report_scene` never fired, `@map_frame` never got set, and
    # every probe that waits on it (move/menu/battle/save) silently never
    # started, even though the game itself was booting and running fine --
    # confirmed by gdb, which caught the process mid-`Tilemap#refresh` on a
    # real map with no crash, just an invisible one to every probe here.
    # `$scene` is checked first since it is cheaper and still correct for
    # XP/VX.
    def self.current_scene
      return $scene unless $scene.nil?
      return nil unless defined?(SceneManager) && SceneManager.respond_to?(:scene)
      begin
        SceneManager.scene
      rescue StandardError
        nil
      end
    end

    # Called once per driven frame, from the wrapper above. Two jobs, both about
    # being able to *see* what a game's own engine is doing from a log:
    #
    #   * report each scene the game moves to (see #current_scene above for
    #     what "the game's own scene" means across RGSS/RGSS2/RGSS3), so this
    #     reads what the game already publishes and modifies nothing.
    #   * with --rgss_host_new_game, tap the confirm key so a headless run gets
    #     off the game's own title screen without a keyboard.
    #   * with --rgss_host_move_test, walk the party once the game's own map
    #     scene is up and report whether it moved.
    #   * with --rgss_host_menu_test, press cancel after that and report which
    #     scene the game went to — its own menu, if it has one.
    #   * with --rgss_host_battle_test, call a battle the way the game's own
    #     Battle Processing command does and report whether it came up.
    #   * with --rgss_host_save_test, the same for its save screen, which is the
    #     one place a game reads a file's timestamp back.
    def self.watch_frame
      @frames += 1
      report_scene
      # While a probe is driving the keyboard, stop tapping confirm: a confirm
      # on a map talks to whatever is in front of the party, and a message
      # window would swallow the walk — or pick an item out of the menu.
      confirm_tap if auto_new_game? && !probing_move? && !probing_menu?
      move_probe if move_test?
      menu_probe if menu_test?
      battle_probe if battle_test?
      save_probe if save_test?
    end

    def self.report_scene
      scene = current_scene
      return if scene.nil?
      name = scene.class.to_s
      return if name == @scene_name
      @scene_name = name
      # Remember when the map first appeared; the move probe waits for it.
      @map_frame = @frames if @map_frame.nil? && map_scene?(name)
      # Every scene the game has been through, for the probes that ask "did it
      # get there" about somewhere it does not *stay* — a save screen hands
      # control back to the map once the file is written, so reading `$scene`
      # when the probe reports would answer Scene_Map either way.
      @scenes_seen ||= []
      @scenes_seen.push(name)
      # The frame number is the diagnostic that matters when a headless run ends
      # on its timeout: it is the only way to tell "the game stalled" from "the
      # frames were slower than the budget" (an unaccelerated CI display renders
      # a 640x480 tilemap far below the 40 fps the constants below assume).
      $stderr.puts "[RPGXP-HOST-SCENE] #{name} frame=#{@frames}"
    end

    # A game's map scene, by the name RGSS gives it. Matched by name rather than
    # by constant because a game is free to rename or subclass it (Pray for You
    # ships its own `Scene_logo` before the title, and community menu scripts
    # replace whole scenes) — what matters is that the party is on a map.
    def self.map_scene?(name)
      name.include?("Scene_Map")
    end

    # A tap a second in, repeated every second: pushed through the same buffer
    # the SDL backend feeds, so the game's own Input.update applies it exactly as
    # it would a real key. Repeated because a game's first screen is its own
    # business — a notice, a language picker, a title menu whose first item is
    # not New Game — and one press cannot know which.
    #
    # The interval is in *frames* while a headless run's budget is in wall-clock
    # milliseconds, so it is kept short: on an unaccelerated CI display the whole
    # boot-plus-walk has to fit in a few hundred frames, and every frame spent
    # waiting for the first tap is one the walk below does not get.
    CONFIRM_EVERY = 40
    CONFIRM_HOLD = 4

    def self.confirm_tap
      phase = @frames % CONFIRM_EVERY
      return if @frames < CONFIRM_EVERY
      RGSS::Input._push(RGSS::Input::C, true) if phase == 0
      RGSS::Input._push(RGSS::Input::C, false) if phase == CONFIRM_HOLD
    end

    # Walk the party leader on the game's own map: hold one direction at a time,
    # cycling through all four, then report where it started and ended.
    #
    # This is the script-host twin of the MV/MZ movement smoke tests, and the
    # rung above "the game reached its map": a game whose own Game_Player reads
    # `Input.dir4` and steps across its own passability is a game being *played*,
    # not merely drawn. All four directions are tried because a start map may
    # have a wall on any one of them, and the keys go through the same buffer the
    # SDL backend feeds, so the game's own Input.update applies them as it would
    # a keyboard.
    #
    # `$game_player` is the game's own global; only its published `x`/`y` are
    # read (see report_scene, which reads the game's own scene the same way).
    #
    # The two counts are a budget, not a preference: the probe finishes
    # MOVE_SETTLE + MOVE_HOLD * MOVE_DIRS frames after the map appears, and a
    # headless run is cut off by wall-clock milliseconds, so a settle long enough
    # to be "safe" is what made the first CI run end on its timeout with the game
    # standing on its map and no walk reported. MOVE_HOLD stays long enough for a
    # default-speed step (a tile takes ~16 frames at move speed 4).
    MOVE_SETTLE = 60        # frames on the map before walking: transitions, autoruns
    MOVE_HOLD = 30          # frames held per direction
    MOVE_DIRS = 4

    def self.probing_move?
      return false unless move_test? && !@map_frame.nil?
      elapsed = @frames - @map_frame
      elapsed >= MOVE_SETTLE && elapsed < MOVE_SETTLE + MOVE_HOLD * MOVE_DIRS
    end

    def self.move_probe
      return if @map_frame.nil? || @move_done
      elapsed = @frames - @map_frame
      return if elapsed < MOVE_SETTLE
      step = elapsed - MOVE_SETTLE
      if step >= MOVE_HOLD * MOVE_DIRS
        finish_move_probe
        return
      end
      dir = move_dirs[step / MOVE_HOLD]
      return unless (step % MOVE_HOLD).zero?
      @move_start ||= player_tile
      # One direction at a time: release the last before holding the next.
      RGSS::Input._push(@move_held, false) unless @move_held.nil?
      @move_held = dir
      RGSS::Input._push(dir, true)
    end

    def self.finish_move_probe
      @move_done = true
      RGSS::Input._push(@move_held, false) unless @move_held.nil?
      @move_held = nil
      from = @move_start
      to = player_tile
      moved = !from.nil? && !to.nil? && from != to
      $stderr.puts "[RPGXP-HOST-MOVE] start=#{tile_s(from)} end=#{tile_s(to)} " \
                   "moved=#{moved} frame=#{@frames}"
    end

    def self.move_dirs
      @move_dirs ||= [RGSS::Input::DOWN, RGSS::Input::LEFT,
                      RGSS::Input::RIGHT, RGSS::Input::UP]
    end

    # Press cancel on the game's own map and report where that took it.
    #
    # The rung above walking. A game's menu is the first thing it draws out of
    # its *own* `Window_Base` subclasses — its windowskin, its font, its
    # `Bitmap#draw_text`, its `Window_Selectable` cursor — none of which a map
    # scene exercises, and all of which this engine supplies natively. So the
    # scene name this reports is a one-line answer to "does the class library
    # hold up once a game starts drawing its own UI".
    #
    # Deliberately only the *first* press: the stock `Scene_Map` opens
    # `Scene_Menu` on `Input.trigger?(Input::B)`, and going deeper would be
    # picking items out of a menu whose contents differ per game.
    MENU_SETTLE = 20        # frames after the walk before pressing cancel
    MENU_HOLD = 4           # frames the cancel key is held
    MENU_WAIT = 60          # frames to let the game's own menu scene come up

    def self.probing_menu?
      menu_test? && !@menu_start.nil? && !@menu_done
    end

    def self.menu_probe
      return if @menu_done || @map_frame.nil?
      # Wait for the walk when there is one: a cancel press mid-walk would open
      # the menu over it and the walk would report nothing.
      return if move_test? && !@move_done
      @menu_start ||= @frames
      step = @frames - @menu_start - MENU_SETTLE
      return if step < 0
      RGSS::Input._push(RGSS::Input::B, true) if step.zero?
      RGSS::Input._push(RGSS::Input::B, false) if step == MENU_HOLD
      finish_menu_probe if step >= MENU_WAIT
    end

    # Whether the game has been through a scene whose name contains `needle`.
    def self.been_through?(needle)
      seen = @scenes_seen
      return false if seen.nil?
      seen.any? { |name| name.include?(needle) }
    end

    # Open the game's own save screen and report whether it got there.
    #
    # Called the way the game's own Save Screen event command does
    # (`Interpreter#command_352` sets `$game_temp.save_calling` and lets
    # `Scene_Map#update` switch scenes), for the same reason the battle probe
    # does: no keypress reaches it from the map, and the alternative — counting
    # cursor presses down a menu — depends on that menu's item order, which every
    # game with a custom menu changes.
    #
    # This is the rung that runs the *save* half of a game's own engine: its
    # `Scene_Save`, its `Window_SaveFile` — which stamps each slot from
    # `File#mtime` and seeds its newest-save search with `Time.at(0)` — and, once
    # the confirm taps pick a slot, its own `save_data` writing a real file. The
    # scene is reported from the scenes the game has *been through*, because a
    # save screen returns to the map as soon as it has written.
    SAVE_SETTLE = 60        # frames on the map before opening the save screen
    SAVE_WAIT = 120         # frames to let it come up and take a confirm

    def self.save_probe
      return if @save_done || @map_frame.nil?
      elapsed = @frames - @map_frame
      return if elapsed < SAVE_SETTLE
      if elapsed == SAVE_SETTLE
        call_save
        return
      end
      finish_save_probe if elapsed >= SAVE_SETTLE + SAVE_WAIT
    end

    def self.call_save
      temp = $game_temp
      return if temp.nil? || !temp.respond_to?(:save_calling=)
      temp.save_calling = true
    end

    def self.finish_save_probe
      @save_done = true
      scene = current_scene
      name = scene.nil? ? "?" : scene.class.to_s
      $stderr.puts "[RPGXP-HOST-SAVE] scene=#{name} " \
                   "reached=#{been_through?("Scene_Save")} frame=#{@frames}"
    end

    # Start a battle in the game's own engine and report where that got it.
    #
    # The rung above the menu, and the biggest surface left: a battle builds the
    # game's own `Spriteset_Battle`, so every enemy is a `Sprite_Battler` —
    # a subclass of the `RPG::Sprite` this gem supplies (rgss_library.rb), whose
    # whiten/appear/collapse transitions, damage pop-up and animation playback
    # nothing had ever run — on top of the battle status and command windows.
    #
    # Unlike the other probes this *writes* to the game's globals rather than
    # only reading them. There is no keypress that starts a battle: the stock
    # `Interpreter#command_301` (Battle Processing) sets exactly these five
    # fields on `$game_temp` and lets `Scene_Map#update` do the rest, so this
    # sets the same five. Walking into a random encounter would be the
    # keypress-only alternative, and it is not deterministic enough for a check.
    # Guarded on the setter existing, since a game may ship its own Game_Temp.
    #
    # Confirm taps keep running through the battle on purpose: that is what
    # advances the game's own party and actor command windows once it is up.
    BATTLE_SETTLE = 60      # frames on the map before calling the battle
    BATTLE_WAIT = 120       # frames to let the game's own battle scene come up
    BATTLE_TROOP_ID = 1

    def self.battle_probe
      return if @battle_done || @map_frame.nil?
      elapsed = @frames - @map_frame
      return if elapsed < BATTLE_SETTLE
      if elapsed == BATTLE_SETTLE
        call_battle
        return
      end
      finish_battle_probe if elapsed >= BATTLE_SETTLE + BATTLE_WAIT
    end

    def self.call_battle
      temp = $game_temp
      return if temp.nil? || !temp.respond_to?(:battle_calling=)
      temp.battle_troop_id = BATTLE_TROOP_ID
      temp.battle_can_escape = true
      temp.battle_can_lose = true
      temp.battle_proc = nil
      temp.battle_calling = true
    end

    def self.finish_battle_probe
      @battle_done = true
      scene = current_scene
      name = scene.nil? ? "?" : scene.class.to_s
      $stderr.puts "[RPGXP-HOST-BATTLE] scene=#{name} " \
                   "reached=#{name.include?("Scene_Battle")} frame=#{@frames}"
    end

    def self.finish_menu_probe
      @menu_done = true
      scene = current_scene
      name = scene.nil? ? "?" : scene.class.to_s
      # "Opened" means the game left its map for something else — which is what
      # cancel does on a stock map, and what a game with its own menu script
      # does too. A game that disables the menu, or one still in its opening
      # cutscene, simply stays put and says so.
      $stderr.puts "[RPGXP-HOST-MENU] scene=#{name} " \
                   "opened=#{!map_scene?(name)} frame=#{@frames}"
    end

    # The party leader's tile, or nil before the game has one.
    def self.player_tile
      player = $game_player
      return nil if player.nil? || !player.respond_to?(:x)
      [player.x, player.y]
    rescue StandardError
      nil
    end

    def self.tile_s(tile)
      tile.nil? ? "?" : "#{tile[0]},#{tile[1]}"
    end

    # `--rgss_host_new_game` / `--rgss_host_move_test`, published by src/main.cxx
    # as constants (this mruby build has no ENV). Read through their own rescue:
    # the constants are absent under the CRuby harnesses, and an undefined
    # constant raises here.
    def self.auto_new_game?
      RGSS_HOST_NEW_GAME
    rescue StandardError
      false
    end

    def self.move_test?
      RGSS_HOST_MOVE_TEST
    rescue StandardError
      false
    end

    def self.menu_test?
      RGSS_HOST_MENU_TEST
    rescue StandardError
      false
    end

    def self.battle_test?
      RGSS_HOST_BATTLE_TEST
    rescue StandardError
      false
    end

    def self.save_test?
      RGSS_HOST_SAVE_TEST
    rescue StandardError
      false
    end
  end
end

# RGSS scripts call load_data / save_data as global Kernel methods that the
# player (RGSS104E.dll) supplies. Define them on Object — the way lib.rb already
# reopens Object for the RGSS value-type names — routed through the script host's
# current database so a loose file and the encrypted archive both resolve. Plain
# method bodies (no runtime class_eval / define_method) so the build needs no
# metaprogramming helpers; they no-op safely until the host sets ScriptHost.db.
class Object
  def load_data(filename)
    RPGXP::ScriptHost.db.read_object(filename)
  end

  def save_data(obj, filename)
    RPGXP::ScriptHost.db.save_object(obj, filename)
  end
end

# Evaluate one RGSS script section. Defined at the TOP LEVEL (not inside
# RPGXP::ScriptHost) on purpose: mruby resolves `class Foo` in eval'd code
# against the *lexical* scope of the method that calls eval, so evaluating from
# inside a module would define the section's classes under that module. Called
# from here, the lexical scope is Object, so `class Scene_Title` etc. become
# global (::) constants — matching how RGSS evaluates the scripts at top level.
# CRuby is handled the same way via TOPLEVEL_BINDING when present (mruby has no
# such constant and a nil-binding eval here already targets the top level);
# const_defined? avoids defined?(CONST), which raises on an unknown constant in
# this mruby build. The section name becomes the "file" in any backtrace.
def rgss_eval_section(source, name)
  top = Object.const_defined?(:TOPLEVEL_BINDING) ? TOPLEVEL_BINDING : nil
  eval(source, top, name, 1)
end
