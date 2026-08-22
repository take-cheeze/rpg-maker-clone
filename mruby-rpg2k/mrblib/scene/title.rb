class RPG2k
  module Scene
    class Title < Base
      # Height of one selectable line. The shinonome font is 12px tall; the
      # extra space gives a little breathing room between entries.
      LINE_HEIGHT = 16
      # draw_text is top-aligned, so nudge the 12px glyphs down to sit centred
      # within the line (and the selection cursor).
      TEXT_PAD_Y = (LINE_HEIGHT - 12) / 2
      # Where RPG_RT parks the title command window: horizontally centred, with
      # its *bottom* edge at 53/60 of the screen height. Measured off a genuine
      # RPG_RT frame (see scripts/compare-nepheshel-wine.bash): for Nepheshel's
      # three 48px-wide labels the window lands at (128, 148) 64x64.
      BOTTOM_NUM = 53
      BOTTOM_DEN = 60
      # RPG_RT unrolls the title command window open over 8 frames (EasyRPG's
      # scene_title.cpp: `command_window->SetOpenAnimation(8)`), skipped under
      # HideTitle -- the centred window appears with the rest of the screen
      # rather than flourishing in on its own.
      OPEN_ANIM_FRAMES = 8

      def initialize parent
        super parent

        # HideTitle (RPG_RT.exe's own legacy CLI arg, parsed in RPG2k#initialize):
        # no title picture, and the command window moves from RPG_RT's usual dock
        # near the picture's bottom edge to the centre of the screen, since there
        # is no picture left to dock against.
        @title = Sprite.new
        @title.bitmap = load_title_picture unless hide_title?

        @menu_items = [
          term(:new_game, 'New Game'),
          term(:continue, 'Continue'),
          term(:shutdown, 'Shutdown')
        ]

        # RPG_RT grays out and skips over Continue when there is no save to
        # resume. `any_save_exists?` (main.rb) covers both our own Marshal
        # saves and a genuine editor Save<N>.lsd dropped into the game dir,
        # across every one of the MAX_SAVE_SLOTS slots -- which one, if any,
        # is now Scene::SaveLoad's own question to ask once Continue opens it.
        @continue_available = continue_available?

        # The cursor always starts on New Game, whether or not a save exists
        # to Continue -- confirmed against a genuine RPG_RT.exe (Nepheshel,
        # under wine): booted three separate times against a valid, working
        # save (Continue enabled and un-grayed, confirmed by successfully
        # opening a correctly-populated file-select screen from it), the
        # title cursor sat on 最初から (New Game) every time, never on 続きから
        # (Continue). `@continue_available` still gates the grayed-out
        # rendering and the disabled-selection buzz below; only the initial
        # cursor position was wrong.
        @selected_index = 0

        # RPG_RT sizes the window to the widest label plus one border on each
        # side — no extra padding — and one 16px row per entry.
        measure = Bitmap.new 1, 1
        content_w = @menu_items.map { |t| measure.text_size(t).width }.max
        content_h = @menu_items.length * LINE_HEIGHT

        window_width = content_w + Window::BORDER * 2
        window_height = content_h + Window::BORDER * 2

        window_x = (WIDTH - window_width) / 2
        window_y =
          if hide_title?
            (HEIGHT - window_height) / 2
          else
            HEIGHT * BOTTOM_NUM / BOTTOM_DEN - window_height
          end

        @window = Window.new window_x, window_y, window_width, window_height
        skin = load_windowskin
        @window.windowskin = skin
        @window.open_animation(hide_title? ? 0 : OPEN_ANIM_FRAMES)

        # Render the (unchanging) menu labels once, in the windowskin's own
        # default text colour (system-colour swatch 0) with RPG_RT's
        # one-pixel shadow. A disabled Continue reads the windowskin's own
        # *disabled* swatch instead -- EasyRPG's `Window_Command::DrawItem`
        # (`src/window_command.cpp`), which `Scene_Title` drives via
        # `command_window->SetItemEnabled(1, continue_enabled)`
        # (`src/scene_title.cpp`), always looks up `Font::ColorDisabled`
        # (`src/font.h`, swatch index 3) rather than hardcoding a flat gray --
        # a custom windowskin whose disabled swatch is tinted (not neutral
        # gray) shows that tint on real RPG_RT, with the same drop-shadow
        # every other label gets. `draw_system_text`'s own no-windowskin
        # fallback (plain `draw_text` in the current font colour) still
        # supplies the flat gray when there is no skin to sample, so the
        # `font.color` set below is unchanged, just no longer the only path.
        contents = Bitmap.new content_w, content_h
        @menu_items.each_with_index do |item, index|
          y = index * LINE_HEIGHT + TEXT_PAD_Y
          if index == 1 && !@continue_available
            contents.font.color = Color.new(128, 128, 128, 255)
            draw_system_text contents, 0, y, content_w, LINE_HEIGHT, item, skin, 3
          else
            contents.font.color = Color.new(255, 255, 255, 255)
            draw_system_text contents, 0, y, content_w, LINE_HEIGHT, item, skin
          end
        end
        @window.contents = contents

        refresh_cursor
        play_title_bgm
      end

      def update
        @window.update

        # Holding Down/Up auto-repeats the cursor after the initial delay,
        # not just a single step per tap -- confirmed against EasyRPG's
        # actual source: `Scene_Title::vUpdate` (`src/scene_title.cpp`)
        # calls `command_window->Update()` unconditionally every frame, a
        # genuine `Window_Command` (`Window_Selectable` subclass) whose own
        # `Update()` is what drives the cursor via the standard
        # trigger-then-repeat (see `Scene::ItemMenu#update_items`'s fuller
        # writeup and docs/TODO.md).
        if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_selection 1
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_selection(-1)
        end

        confirmed = Input.trigger?(Input::C)
        if confirmed && @selected_index == 1 && !@continue_available
          # Continue is grayed out with nothing to resume, but confirming it
          # anyway is not silent -- confirmed against EasyRPG's own
          # `Scene_Title::CommandContinue`, whose disabled branch is
          # `SePlay(...SFX_Buzzer...); return;`, not a plain no-op (the
          # enabled check lives inside the handler itself, not a guard in
          # `vUpdate()` around calling it at all).
          play_system_se(SFX_BUZZER)
        elsif confirmed || (auto = auto_select?)
          case @selected_index
          when 0  # New Game
            # RPG_RT does not hard-cut the title music -- `Player::
            # SetupNewGame` (`src/player.cpp`) is `Main_Data::game_system->
            # BgmFade(800, true); ...`, an 800ms fade, not `BgmStop()`'s
            # immediate stop (the two are genuinely different `Game_System`
            # calls, confirmed against `src/game_system.cpp`). The blanket
            # `Audio.bgm_stop` this method used to run before every
            # selection (including this one) skipped straight to silence
            # instead.
            Audio.bgm_fade(800)
            play_system_se(SFX_DECISION)
            parent.start_new_game
          when 1  # Continue
            # A real player picks the slot themselves on the file-select list
            # (Scene::SaveLoad) Continue now opens. --rpg2k_continue has no
            # input loop to drive a second screen, so it keeps resuming slot 1
            # directly instead -- the same single-slot behaviour Continue had
            # before this screen existed, which is all
            # scripts/compare-nepheshel-wine.bash (watching stderr for the
            # [RPG2k-MAP] marker only #continue_game emits) needs.
            #
            # The headless auto-select path fades here too, matching
            # `Player::LoadSavegame`'s own `if (!load_on_map) { BgmFade(800);
            # ... }` (`src/player.cpp`) -- true from the title, the only case
            # this shortcut ever takes. The interactive `Scene::SaveLoad`
            # push is deliberately left alone: that scene's own `:load` mode
            # is shared with the RPG2003 in-map "Open Load Menu" event
            # (`Scene::Map#perform_event_load`), which per
            # `LoadSavegame`'s own `load_on_map` guard must NOT fade --
            # giving the title-only path its own fade needs a flag threaded
            # through `SaveLoad.new`, left as a separate, well-scoped
            # follow-up rather than folded in here.
            play_system_se(SFX_DECISION)
            if auto
              Audio.bgm_fade(800)
              parent.continue_game
            else
              parent.push(Scene::SaveLoad.new(parent, nil, :load))
            end
          when 2  # Shutdown
            # No confirmation dialog -- EasyRPG's own `CommandShutdown` plays
            # Decision then exits immediately (a fade-out transition into
            # `Scene::Pop`), unlike the field menu's own End Game command,
            # which pushes a yes/no confirm screen this runtime does not
            # model either. `CommandShutdown` (`src/scene_title.cpp`) makes
            # no BGM call at all -- confirmed by reading its full body -- so
            # this branch touches neither `bgm_fade` nor `bgm_stop`, matching
            # the blanket `Audio.bgm_stop` this method used to run
            # unconditionally before every selection, this one included.
            play_system_se(SFX_DECISION)
            exit
          end
        end
      end

      def dispose
        @title.dispose
        @window.dispose
      end

      private

      # `--rpg2k_new_game` / `--rpg2k_continue`: pick a title entry once,
      # without input, so a headless run reaches the map renderer instead of
      # sitting on the title screen. One-shot; a no-op during normal play.
      #
      # New Game wins if both are set: it needs no save data, so it is the one
      # that cannot fail for an unrelated reason.
      #
      # Each flag is read through its own `begin`/`rescue` rather than a helper
      # taking the constant's name: `Module#const_get` is not something this
      # runtime's mruby build is known to carry, and the whole point of these
      # flags is catching mruby/CRuby divergence, not adding more (ADR 0021).
      def auto_select?
        return false if @auto_started
        if auto_new_game?
          @auto_started = true
          @selected_index = 0
          if (map_id = preview_map_id)
            $stderr.puts "[RPG2k] --rpg2k_preview_map=#{map_id}: selecting New Game"
          elsif battle_troop
            $stderr.puts "[RPG2k] --rpg2k_battle_troop=#{battle_troop}: selecting New Game"
          else
            $stderr.puts '[RPG2k] --rpg2k_new_game: selecting New Game'
          end
          true
        elsif auto_continue?
          @auto_started = true
          @selected_index = 1
          $stderr.puts '[RPG2k] --rpg2k_continue: selecting Continue'
          true
        else
          false
        end
      end

      # --rpg2k_preview_map / --rpg2k_battle_troop also trigger this (see
      # #preview_map_id / #battle_troop below), so each needs only its own
      # flag, not this one too. Each source is
      # read through its own `begin`/`rescue` rather than a shared helper: an
      # undefined constant (either flag, checked independently) must not sink
      # the other, which a single `RPG2K_NEW_GAME || preview_map_id` guarded by
      # one outer rescue would do -- resolving the bare, undefined
      # RPG2K_NEW_GAME raises before `||` ever reaches preview_map_id.
      def auto_new_game?
        new_game_flag? || preview_map_id || battle_troop
      end

      def new_game_flag?
        RPG2K_NEW_GAME
      rescue StandardError
        false
      end

      def auto_continue?
        RPG2K_CONTINUE
      rescue StandardError
        false
      end

      # --rpg2k_preview_map also auto-selects New Game (see #auto_new_game?
      # above), so a preview needs only that one flag. Guarded the same way as
      # #hide_title?/#continue_available? below: a bare Title built without a
      # real parent (scripts/rpg2k_scene_check.rb) answers nil rather than
      # raising.
      def preview_map_id
        parent.preview_map_id
      rescue StandardError
        nil
      end

      # --rpg2k_battle_troop also auto-selects New Game (see #auto_new_game?
      # above): a headless battle needs the map up first, which New Game is
      # what provides, so the flag implies it. Guarded the same way as
      # #preview_map_id just above.
      def battle_troop
        parent.headless_battle_troop
      rescue StandardError
        nil
      end

      # HideTitle, as RPG2k#initialize parsed it off RPG_RT.exe's legacy CLI
      # arguments. Guarded the same way as the two flags above: a bare instance
      # built without a real parent (see scripts/rpg2k_scene_check.rb's
      # title_selector) answers false rather than raising.
      def hide_title?
        parent.hide_title?
      rescue StandardError
        false
      end

      # Whether Continue has anything to resume, per `RPG2k#any_save_exists?`.
      # Guarded the same way as `hide_title?` above: a bare instance built
      # without a real parent (see scripts/rpg2k_scene_check.rb's
      # title_selector) answers false rather than raising.
      def continue_available?
        parent.any_save_exists?
      rescue StandardError
        false
      end

      # Move `@selected_index` by `delta` (+1/-1), wrapping around the menu.
      # A grayed-out Continue is still reachable by the cursor -- only the
      # selection key is ignored on it (see #update).
      def move_selection(delta)
        @selected_index = (@selected_index + delta) % @menu_items.length
        play_cursor_se
        refresh_cursor
      end

      # The database's title picture. Returns nil (drawing nothing, same as
      # HideTitle) when the game names none or the file fails to load — every
      # other asset loader in this scene stack degrades the same way (see
      # #load_windowskin below and Scene::GameOver#gameover_bitmap), and the
      # title screen showing a blank background beats an unhandled exception
      # blocking New Game before a single frame is drawn.
      def load_title_picture
        name = db.system.title.to_s
        return nil if name.empty?
        Bitmap.new "Title/#{name}"
      rescue StandardError => e
        $stderr.puts "[RPG2k] title picture '#{name}' load failed, showing a " \
                     "blank background: #{e.message}"
        nil
      end

      # Load the System/ windowskin declared in the database. Returns nil when
      # it is missing so the Window falls back to a plain panel instead of
      # crashing.
      def load_windowskin
        name = db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      def refresh_cursor
        @window.cursor_rect =
          Rect.new(0, @selected_index * LINE_HEIGHT, @window.contents.width,
                   LINE_HEIGHT)
      end

      # Play the database's "cursor move" sound effect (System > cursor SE) when
      # the menu selection changes. A no-op when the game defines no cursor SE,
      # the file is missing, or no audio backend is installed.
      def play_cursor_se
        se = db.system.cursor_se
        return unless se
        name = se.file
        return if name.nil? || name.empty?
        Audio.se_play name, se.volume, se.pitch
      rescue StandardError => e
        $stderr.puts "[RGSS] cursor SE playback failed: #{e.message}"
      end

      # Play the database's title music (System > title BGM), as RPG_RT does
      # when the title screen comes up. Re-entering the title (Return to Title)
      # builds a new scene and so restarts it, which is what RPG_RT does too.
      #
      # `fade_in` is read from the record but not honoured: the audio backend
      # can fade a BGM out, not in (see ADR 0006), so the music starts at full
      # volume. A no-op when the game defines no title music, the file is
      # missing, or no audio backend is installed.
      def play_title_bgm
        bgm = db.system.title_music
        return unless bgm
        name = bgm.file
        return if name.nil? || name.empty?
        Audio.bgm_play name, (bgm.volume || 100), (bgm.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RPG2k] title BGM playback failed: #{e.message}"
      end
    end
  end
end
