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

        # Render the (unchanging) menu labels once, in the windowskin's own
        # default text colour with RPG_RT's one-pixel shadow.
        contents = Bitmap.new content_w, content_h
        contents.font.color = Color.new(255, 255, 255, 255)
        @menu_items.each_with_index do |item, index|
          draw_system_text contents, 0, index * LINE_HEIGHT + TEXT_PAD_Y,
                           content_w, LINE_HEIGHT, item, skin
        end
        @window.contents = contents

        refresh_cursor
        play_title_bgm
      end

      def update
        if Input.trigger?(Input::DOWN)
          @selected_index += 1
          @selected_index %= 3
          play_cursor_se
          refresh_cursor
        elsif Input.trigger?(Input::UP)
          @selected_index -= 1
          @selected_index %= 3
          play_cursor_se
          refresh_cursor
        end

        if Input.trigger?(Input::C) || auto_select?
          Audio.bgm_stop
          case @selected_index
          when 0  # New Game
            parent.start_new_game
          when 1  # Continue
            parent.continue_game
          when 2  # Shutdown
            exit
          end
        end

        @window.update
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
          $stderr.puts '[RPG2k] --rpg2k_new_game: selecting New Game'
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

      def auto_new_game?
        RPG2K_NEW_GAME
      rescue StandardError
        false
      end

      def auto_continue?
        RPG2K_CONTINUE
      rescue StandardError
        false
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
