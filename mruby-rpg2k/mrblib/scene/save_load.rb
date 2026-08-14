class RPG2k
  module Scene
    # RPG2000's save-select screen: a scrollable list of the MAX_SAVE_SLOTS
    # file slots, each showing the party leader, level, HP, gold and current
    # map when the slot holds a save, or a "no data" placeholder when it does
    # not. Pushed in two shapes:
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
      # Two text lines per slot: the file label/name/level row, and the
      # HP/gold/map row beneath it.
      ROW_H = LINE_H * 2
      HEADER_H = LINE_H + Window::BORDER * 2

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
        build_header_window
        build_list_window
      end

      def dispose
        close_message
        @header_window.dispose if @header_window
        @list_window.dispose if @list_window
      end

      def update
        return drive_message if @message

        if Input.trigger?(Input::B)
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

      def visible_rows
        [(@list_window.height - Window::BORDER * 2) / ROW_H, 1].max
      end

      def move_selection(delta)
        @index = (@index + delta) % SLOT_COUNT
        @top = @index if @index < @top
        @top = @index - visible_rows + 1 if @index >= @top + visible_rows
        draw_list_contents
      end

      def confirm_selection
        slot = @index + 1
        case @mode
        when :save
          ok = @parent.save_game(@state, slot)
          @slots[@index] = @parent.load_save_state(slot) if ok
          draw_list_contents
          show_message(ok ? "Game saved." : "Save failed.")
        when :load
          # An empty slot has nothing to resume -- ignored, like the
          # selection key on a title screen Continue with no save at all
          # (Scene::Title#update).
          @parent.continue_game(slot) if @slots[@index]
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

      def build_list_window
        y = HEADER_H
        @list_window = Window.new(0, y, SCREEN_W, SCREEN_H - y)
        @list_window.z = 400
        @list_window.windowskin = @skin
        draw_list_contents
      end

      # Redraw the list window's contents for the current scroll offset
      # (`@top`) and reposition the cursor onto the selected row -- called
      # whenever the selection moves or a save just changed a slot's preview.
      def draw_list_contents
        inner_w = @list_window.width - Window::BORDER * 2
        rows = visible_rows
        c = Bitmap.new(inner_w, rows * ROW_H)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.times do |i|
          slot_index = @top + i
          break if slot_index >= SLOT_COUNT
          draw_slot_row(c, i * ROW_H, inner_w, slot_index)
        end
        @list_window.contents = c
        @list_window.cursor_rect =
          Rect.new(0, (@index - @top) * ROW_H, inner_w, ROW_H)
      end

      def slot_label(slot_index)
        slot = slot_index + 1
        n = slot < 10 ? "0#{slot}" : "#{slot}"
        "#{term(:file, 'File')} #{n}"
      end

      def draw_slot_row(c, y, w, slot_index)
        label = slot_label(slot_index)
        state = @slots[slot_index]
        unless state
          c.draw_text 0, y, w, LINE_H, label
          c.draw_text 0, y + LINE_H, w, LINE_H, "-- No Data --"
          return
        end
        leader = state.party.leader
        name = leader ? leader.name.to_s : ''
        level = leader ? leader.level : 0
        hp = leader ? leader.hp : 0
        max_hp = leader ? leader.max_hp : 0
        c.draw_text 0, y, w, LINE_H,
                    "#{label}  #{name}  #{term(:level_short, 'Lv')}#{level}"
        c.draw_text 0, y + LINE_H, w, LINE_H,
                    "#{term(:hp_short, 'HP')} #{hp}/#{max_hp}  " \
                    "#{state.party.gold}#{term(:gold, 'G')}  " \
                    "#{map_display_name(state.map_id)}"
      end

      # A map's editor name, or its bare id when the tree carries no name for
      # it -- mirrors Scene::ItemMenu#map_display_name /
      # Scene::SkillMenu#map_display_name (the teleport destination pickers),
      # each keeping their own copy rather than sharing one through Base.
      def map_display_name(map_id)
        row = map_tree.respond_to?(:map_properties) ? map_tree.map_properties[map_id] : nil
        name = row && row.respond_to?(:name) ? row.name.to_s : nil
        name.nil? || name.empty? ? "Map #{map_id}" : name
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
