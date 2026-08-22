class RPG2k
  module Scene
    # Debug-only passability editor for the current map's chipset, opened from
    # the F9 debug menu's Chipset page. RPG Maker's own chipset editor is a
    # visual grid because passability is spatial data (which of 162 lower / 144
    # upper cells is walkable) -- exactly the "hard to edit with text" case
    # `docs/adr/0055-lcf-text-convert.md` carved the map itself out for, and
    # the chipset's passability table is the same shape of problem. Unlike
    # that map, though, this draws no real tile art either (same simplifying
    # choice Scene::MapViewer makes, see its own comment) -- each of the grid's
    # 16x16 cells is a solid colour block (green passable, dark red blocked),
    # not the chipset's actual graphic. Fine per-field edits this doesn't cover
    # (terrain id, water-animation speed, ...) are still reachable through
    # scripts/lcf_text_convert.rb.
    #
    # L switches between the Lower (162 cells) and Upper (144 cells) tables;
    # arrow keys move the cell cursor; C toggles passability on the selected
    # cell -- coarse, all four direction bits at once (whichever way
    # Game::ChipSet#landable_tile?'s own "passable from *some* direction" read
    # would colour it), not per-direction fine control, and only those four
    # bits: an upper cell's ABOVE_BIT ("star", draws in front of the hero) and
    # COUNTER_BIT (talk-across) are preserved untouched by the toggle. R
    # writes the database back to its .ldb file and rebuilds the live map's
    # chipset (Scene::Map#rebuild_chipset) so the edit is visible in the field
    # map immediately, not just on the next map load -- edits are NOT applied
    # to the live game before R, unlike Scene::MapViewer's Edit mode (which
    # reads the very arrays it paints); rebuilding a chipset also reloads its
    # tile graphic from disk, so this only pays that cost once, on save,
    # rather than once per toggle. B closes back to the debug menu.
    class ChipsetEditor < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      HEADER_H = 16
      # Two lines tall -- see MapViewer::FOOTER_H's own comment; this editor's
      # hint fits below the grid either way (rows * CELL always leaves more
      # than FOOTER_H px of slack), but the constant stays honest about how
      # tall #draw_footer can actually draw.
      FOOTER_H = HEADER_H * 2
      CELL = 16
      COLS = 18
      LOWER_COUNT = 162
      UPPER_COUNT = 144

      PASSABLE_COLOR = Color.new(64, 160, 64, 255)
      BLOCKED_COLOR = Color.new(160, 48, 48, 255)
      UNKNOWN_COLOR = Color.new(96, 96, 96, 255)
      CURSOR_COLOR = Color.new(255, 255, 255, 255)
      TEXT_COLOR = Color.new(255, 255, 255, 255)
      HINT_COLOR = Color.new(200, 200, 200, 255)

      # `quit_on_close:` -- set by RPG2k#open_chipset_editor (the
      # --rpg2k_chipset_editor flag) -- makes B quit the whole process instead
      # of popping back to whatever this editor was pushed on top of. See
      # Scene::MapViewer#initialize's own comment on the identical parameter:
      # the flag pushes this scene straight onto a freshly-built Scene::Map,
      # skipping F9 entirely, so an ordinary #pop would drop into an ordinary,
      # playable field map instead of ending the run. Left false (the
      # default) for F9's own Chipset page, where popping back to the debug
      # menu underneath is exactly the wanted behaviour.
      def initialize(parent, state, quit_on_close: false)
        super parent
        @state = state
        @quit_on_close = quit_on_close
        @chipset_id = state.map ? state.map.chipset_id : 1
        @chip = @db.respond_to?(:chipset) ? @db.chipset[@chipset_id] : nil
        @skin = make_windowskin
        @background = build_field_background(@skin)
        @window = Window.new(0, 0, SCREEN_W, SCREEN_H)
        @window.z = 400
        @window.windowskin = @skin
        @contents = Bitmap.new(SCREEN_W - Window::BORDER * 2, SCREEN_H - Window::BORDER * 2)
        @window.contents = @contents
        @tab = :lower
        @idx = 0
        @dirty = false
        refresh
      end

      def dispose
        @background.dispose if @background
        @window.dispose if @window
      end

      def update
        if Input.trigger?(Input::B)
          close
        elsif Input.trigger?(Input::L)
          switch_tab
        elsif Input.trigger?(Input::C)
          toggle_passable
        elsif Input.trigger?(Input::R)
          save_to_disk
        elsif move_cursor
          refresh
        end
      end

      private

      # See @quit_on_close's own comment on #initialize.
      def close
        return exit if @quit_on_close
        @parent.pop
      end

      def switch_tab
        @tab = @tab == :lower ? :upper : :lower
        @idx = 0
        refresh
      end

      def cell_count
        @tab == :lower ? LOWER_COUNT : UPPER_COUNT
      end

      def rows
        (cell_count + COLS - 1) / COLS
      end

      def move_cursor
        moved = false
        col = @idx % COLS
        row = @idx / COLS
        if (Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)) && col.positive?
          @idx -= 1
          moved = true
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) &&
              col < COLS - 1 && @idx < cell_count - 1
          @idx += 1
          moved = true
        end
        if (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && row.positive?
          @idx -= COLS
          moved = true
        elsif (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) &&
              @idx + COLS < cell_count
          @idx += COLS
          moved = true
        end
        moved
      end

      # The passability byte table for the active tab, materialised to a full
      # LOWER_COUNT/UPPER_COUNT-length array of the schema's implicit "no table
      # at all" reading (Game::ChipSet: nil lower means always passable, nil
      # upper means the lower layer alone decides) when the chipset has never
      # had one -- rather than leaving nil to editing (or the debug menu's own
      # #index_valid? pattern would have to special-case it everywhere).
      def current_bytes
        return nil unless @chip
        if @tab == :lower
          @chip.passable_data_lower || Array.new(LOWER_COUNT, Game::ChipSet::ALL_DIRS)
        else
          @chip.passable_data_upper || Array.new(UPPER_COUNT, 0)
        end
      end

      def toggle_passable
        return unless @chip
        bytes = current_bytes
        bytes[@idx] = toggled_byte(bytes[@idx] || 0)
        @chip[@tab == :lower ? 4 : 5] = bytes
        @dirty = true
        refresh
      end

      # Flip only the four direction bits (ALL_DIRS) between fully-clear and
      # fully-set, leaving any other bit -- ABOVE_BIT/COUNTER_BIT on an upper
      # cell -- exactly as it was. "Currently passable" reads the same
      # any-direction-set rule Game::ChipSet#landable? uses, so the toggle
      # always flips to the opposite of what the cell is already drawn as.
      def toggled_byte(byte)
        passable = (byte & Game::ChipSet::ALL_DIRS) != 0
        passable ? (byte & ~Game::ChipSet::ALL_DIRS) : (byte | Game::ChipSet::ALL_DIRS)
      end

      def save_to_disk
        return unless @chip && @dirty
        @db.save_to(@parent.db_path)
        map_scene = @parent.respond_to?(:map_scene) ? @parent.map_scene : nil
        map_scene.rebuild_chipset if map_scene.respond_to?(:rebuild_chipset)
        @dirty = false
        refresh
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset editor save failed: #{e.message}"
      end

      def refresh
        @contents.clear
        draw_header
        draw_grid
        draw_cursor
        draw_footer
      end

      def draw_header
        @contents.font.color = TEXT_COLOR
        text = if !@chip
                 "Chipset ##{@chipset_id} not found in the database"
               else
                 dirty = @dirty ? '  *unsaved*' : ''
                 "Chipset ##{@chipset_id} #{@tab} [#{@idx}]  #{cell_word}#{dirty}"
               end
        @contents.draw_text 0, 0, @contents.width, HEADER_H, text
      end

      def cell_word
        color = cell_color(@idx)
        return 'unknown' if color.equal?(UNKNOWN_COLOR)
        color.equal?(PASSABLE_COLOR) ? 'passable' : 'blocked'
      end

      def draw_footer
        @contents.font.color = HINT_COLOR
        hint = 'Arrows:Move  L:Tab  C:Toggle  R:Save  B:Close'
        draw_wrapped_hint(hint, HEADER_H + rows * CELL, HEADER_H)
      end

      def draw_grid
        bytes = current_bytes
        (0...cell_count).each do |i|
          color = bytes ? cell_color_for(bytes[i] || 0) : UNKNOWN_COLOR
          col = i % COLS
          row = i / COLS
          @contents.fill_rect col * CELL, HEADER_H + row * CELL, CELL - 1, CELL - 1, color
        end
      end

      def cell_color(idx)
        bytes = current_bytes
        return UNKNOWN_COLOR unless bytes
        cell_color_for(bytes[idx] || 0)
      end

      def cell_color_for(byte)
        (byte & Game::ChipSet::ALL_DIRS) != 0 ? PASSABLE_COLOR : BLOCKED_COLOR
      end

      def draw_cursor
        col = @idx % COLS
        row = @idx / COLS
        x = col * CELL
        y = HEADER_H + row * CELL
        @contents.fill_rect x, y, CELL - 1, 1, CURSOR_COLOR
        @contents.fill_rect x, y + CELL - 2, CELL - 1, 1, CURSOR_COLOR
        @contents.fill_rect x, y, 1, CELL - 1, CURSOR_COLOR
        @contents.fill_rect x + CELL - 2, y, 1, CELL - 1, CURSOR_COLOR
      end
    end
  end
end
