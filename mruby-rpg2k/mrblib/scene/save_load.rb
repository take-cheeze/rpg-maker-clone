class RPG2k
  module Scene
    # RPG2000's save-select screen: a scrollable list of the MAX_SAVE_SLOTS
    # file slots, each its own bordered box (not rows in one shared list
    # window) showing the party leader, level and HP when the slot holds a
    # save, or just the file label when it does not -- confirmed against
    # genuine RPG_RT under wine (see VISIBLE_SLOTS/SLOT_BOX_H below for the
    # specifics this ports). Pushed in two shapes:
    #
    #   * `:save`, from Scene::Menu's Save command, with the running
    #     Game::State to write out. Every slot -- occupied or not -- is
    #     selectable; confirming one calls RPG2k#save_game(state, slot) and
    #     shows the same "Game saved." / "Save failed." feedback the menu
    #     used to show inline, then returns to the menu.
    #   * `:load`, from Scene::Title's Continue entry, with `state` nil (there
    #     is no running game yet). Only an occupied slot is selectable;
    #     confirming one calls RPG2k#continue_game(slot), which tears down the
    #     whole scene stack (this screen included) and enters the map -- the
    #     same transition Continue always performed, just now aimed at
    #     whichever slot the player picked instead of a hardcoded one.
    #
    # Cancelling (B) always just pops back to whichever scene pushed this one.
    #
    # Every slot's preview is read once, up front, through
    # RPG2k#load_save_state -- the same "our own .mrb, else a genuine
    # Save<N>.lsd, else empty" lookup #continue_game itself uses, so the list
    # shows exactly what Continue would resume.
    class SaveLoad < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      SLOT_COUNT = RPG2k::MAX_SAVE_SLOTS
      LINE_H = 16
      HEADER_H = LINE_H + Window::BORDER * 2

      # Each visible slot is its own bordered window, three text lines tall
      # (file label, leader name, level+HP) -- confirmed against genuine
      # RPG_RT under wine, which draws File 1/2/3 as three separate boxes
      # stacked below the header, not rows inside one shared list window
      # (scripts/rpg2k_scene_check.rb's fixtures aside, a real screenshot
      # showed each box's own purple border independently). An empty slot's
      # box shows only the label line, the other two blank -- no "No Data"
      # placeholder text at all, the same class of gap the Item/Skill empty-
      # list placeholders turned out to be (see docs/TODO.md).
      SLOT_LINES = 3
      SLOT_BOX_H = LINE_H * SLOT_LINES + Window::BORDER * 2

      # (SCREEN_H - HEADER_H) / SLOT_BOX_H, i.e. how many slot boxes fit
      # below the header -- 3 on RPG2000's 320x240 screen (32 + 3*64 = 224,
      # leaving 16px for a scroll indicator this port does not draw yet).
      # Matches the reference capture exactly: three boxes on screen, the
      # rest reached by scrolling.
      VISIBLE_SLOTS = (SCREEN_H - HEADER_H) / SLOT_BOX_H

      def initialize parent, state, mode
        super parent
        @state = state
        @mode = mode # :save or :load
        @skin = make_windowskin
        # One Game::State (or nil for an empty slot) per slot, read once so
        # scrolling the list never re-touches disk.
        @slots = (1..SLOT_COUNT).map { |slot| parent.load_save_state(slot) }
        @index = 0
        @top = 0
        @message = nil
        @slot_windows = []
        build_header_window
        build_slot_windows
      end

      def dispose
        close_message
        @header_window.dispose if @header_window
        @slot_windows.each(&:dispose)
      end

      def update
        return drive_message if @message

        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN)
          move_selection 1
        elsif Input.trigger?(Input::UP)
          move_selection(-1)
        elsif Input.trigger?(Input::C)
          confirm_selection
        end
      end

      private

      def move_selection(delta)
        @index = (@index + delta) % SLOT_COUNT
        @top = @index if @index < @top
        @top = @index - VISIBLE_SLOTS + 1 if @index >= @top + VISIBLE_SLOTS
        refresh_slot_windows
        play_system_se(SFX_CURSOR)
      end

      def confirm_selection
        slot = @index + 1
        case @mode
        when :save
          play_system_se(SFX_DECISION)
          ok = @parent.save_game(@state, slot)
          @slots[@index] = @parent.load_save_state(slot) if ok
          refresh_slot_windows
          show_message(ok ? "Game saved." : "Save failed.")
        when :load
          # An empty slot has nothing to resume -- refused (Buzzer), like the
          # selection key on a title screen Continue with no save at all
          # (Scene::Title#update).
          if @slots[@index]
            play_system_se(SFX_DECISION)
            @parent.continue_game(slot)
          else
            play_system_se(SFX_BUZZER)
          end
        end
      end

      def build_header_window
        @header_window = Window.new(0, 0, SCREEN_W, HEADER_H)
        @header_window.z = 400
        @header_window.windowskin = @skin
        inner_w = SCREEN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        header = @mode == :save ? term(:save_file_select, 'Save which file?') :
                                   term(:load_file_select, 'Load which file?')
        c.draw_text 0, 0, inner_w, LINE_H, header
        @header_window.contents = c
      end

      def build_slot_windows
        VISIBLE_SLOTS.times do |i|
          w = Window.new(0, HEADER_H + i * SLOT_BOX_H, SCREEN_W, SLOT_BOX_H)
          w.z = 400
          w.windowskin = @skin
          @slot_windows << w
        end
        refresh_slot_windows
      end

      # Redraw every visible slot box for the current scroll offset (`@top`)
      # and put the cursor on the selected one -- called whenever the
      # selection moves or a save just changed a slot's preview.
      def refresh_slot_windows
        inner_w = SCREEN_W - Window::BORDER * 2
        @slot_windows.each_with_index do |win, i|
          slot_index = @top + i
          draw_slot_box(win, inner_w, slot_index)
        end
      end

      def slot_label(slot_index)
        "#{term(:file, 'File')} #{slot_index + 1}"
      end

      # `slot_index`'s box: the file label always, and -- when the slot holds
      # a save -- the leader's name and level+HP beneath it. Confirmed
      # against genuine RPG_RT under wine: an empty slot shows only the
      # label (no placeholder text at all), and an occupied one shows
      # neither gold nor the current map, and HP with no `/max`, unlike this
      # screen's own previous single-list-window layout.
      def draw_slot_box(win, inner_w, slot_index)
        label = slot_label(slot_index)
        c = Bitmap.new(inner_w, LINE_H * SLOT_LINES)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, LINE_H, label
        state = @slots[slot_index]
        if state
          leader = state.party.leader
          name = leader ? leader.name.to_s : ''
          level = leader ? leader.level : 0
          hp = leader ? leader.hp : 0
          c.draw_text 0, LINE_H, inner_w, LINE_H, name
          c.draw_text 0, LINE_H * 2, inner_w, LINE_H,
                      "#{term(:level_short, 'Lv')}#{level}    " \
                      "#{term(:hp_short, 'HP')}#{hp}"
        end
        win.contents = c
        win.cursor_rect = if slot_index == @index
                             Rect.new(0, 0, c.text_size(label).width, LINE_H)
                           else
                             Rect.new(0, 0, 0, 0)
                           end
      end

      # The "Game saved." / "Save failed." feedback banner, mirroring
      # Scene::Menu's own #show_message/#drive_message/#close_message: shown
      # after a :save confirm, dismissed by the player, and only then does
      # this screen pop back to the menu -- so the message is never missed.
      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        close_message
        @parent.pop
      end

      def show_message(text)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - LINE_H - Window::BORDER * 2 - 4, w,
                         LINE_H + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, LINE_H, text
        win.contents = c
        @message = { window: win }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end
  end
end
