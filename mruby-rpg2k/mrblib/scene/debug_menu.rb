class RPG2k
  module Scene
    # RPG_RT's F9 debug menu (see Scene::Map#try_open_debug_menu -- Test Play
    # only, opened from the field map). Two flip-able pages, Switch and
    # Variable, each listing ten ids at a time: Left/Right flips between the
    # two pages, Up/Down moves the cursor by one row (scrolling into the
    # neighbouring block of ten at either edge), L/R jumps a full block of ten,
    # C acts on the selected row (toggle a switch instantly, or open a signed
    # number editor for a variable) and B closes the menu.
    #
    # The id range shown extends to cover every switch/variable the project
    # actually names (its LDB "switch"/"variable" tables, chunks 23/24 --
    # `db.switch[id].name` / `db.variable[id].name`) or has already set a
    # value for this session, with a floor of FLOOR_ID ids so an unauthored
    # game still has something to browse and toggle. RPG2000 itself has no
    # fixed switch/variable count for this menu to reproduce -- Control
    # Switches/Variables accepts any id -- so this is a practical window onto
    # the ids in play rather than a claim about an engine cap.
    class DebugMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      PAGE_SIZE = 10
      LINE_H = 16
      NAME_COL_W = 208
      FLOOR_ID = 100

      def initialize(parent, state)
        super parent
        @state = state
        @skin = make_windowskin
        @background = build_field_background(@skin)
        @mode = :switch
        @page = 0
        @cursor = 0
        @editor = nil
        build_window
      end

      def dispose
        close_editor
        @background.dispose if @background
        @window.dispose if @window
      end

      def update
        return update_editor if @editor
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::LEFT) || Input.trigger?(Input::RIGHT)
          @mode = @mode == :switch ? :variable : :switch
          @page = 0
          @cursor = 0
          refresh
        elsif Input.trigger?(Input::DOWN)
          move_cursor(1)
        elsif Input.trigger?(Input::UP)
          move_cursor(-1)
        elsif Input.trigger?(Input::R)
          turn_page(1)
        elsif Input.trigger?(Input::L)
          turn_page(-1)
        elsif Input.trigger?(Input::C)
          activate_row
        end
      end

      private

      def max_page
        (max_id - 1) / PAGE_SIZE
      end

      def move_cursor(delta)
        n = @cursor + delta
        if n.negative?
          return if @page.zero?
          @page -= 1
          n = PAGE_SIZE - 1
        elsif n >= PAGE_SIZE
          return if @page >= max_page
          @page += 1
          n = 0
        end
        @cursor = n
        refresh
      end

      def turn_page(delta)
        p = @page + delta
        return if p.negative? || p > max_page
        @page = p
        @cursor = 0
        refresh
      end

      def current_id
        @page * PAGE_SIZE + @cursor + 1
      end

      def max_id
        table = @mode == :switch ? db.switch : db.variable
        values = @mode == :switch ? @state.switches : @state.variables
        ids = [FLOOR_ID]
        # A project that never named a switch/variable in the editor (or, in
        # RPG2000, one where the switch/variable chunk was simply never
        # written) has no `db.switch`/`db.variable` table at all -- LCF.to_rb
        # falls back to the schema default for an absent chunk, and chunks 23
        # / 24 carry none (see mruby-lcf/mrblib/schema.rb), so it comes back
        # nil rather than an empty table.
        table.each { |id, _| ids << id } if table
        values.to_h.each { |id, _| ids << id }
        ids.max
      end

      def activate_row
        id = current_id
        if @mode == :switch
          @state.switches[id] = !@state.switches[id]
          refresh
        else
          open_editor(id)
        end
      end

      def row_name(id)
        table = @mode == :switch ? db.switch : db.variable
        row = table && table[id]
        name = row && row.respond_to?(:name) ? row.name : nil
        name.nil? ? '' : name
      end

      def row_value_text(id)
        @mode == :switch ? (@state.switches[id] ? 'ON' : 'OFF') : @state.variables[id].to_s
      end

      # Zero-padded to (at least) 4 digits, e.g. 7 -> "0007", 12345 -> "12345".
      # No String#% / Kernel#sprintf here -- mruby-rpg2k does not depend on
      # mruby-sprintf, and this is the only place that would need it.
      def id_label(id)
        s = id.to_s
        s = '0' + s while s.length < 4
        s
      end

      def build_window
        w = SCREEN_W - 32
        h = (PAGE_SIZE + 1) * LINE_H + Window::BORDER * 2
        @window = Window.new(16, 16, w, h)
        @window.z = 400
        @window.windowskin = @skin
        @contents = Bitmap.new(w - Window::BORDER * 2, (PAGE_SIZE + 1) * LINE_H)
        @window.contents = @contents
        refresh
      end

      def refresh
        return unless @contents
        @contents.clear
        @contents.font.color = Color.new(255, 255, 255, 255)
        title = @mode == :switch ? 'Switch' : 'Variable'
        first = @page * PAGE_SIZE + 1
        last = [first + PAGE_SIZE - 1, max_id].min
        @contents.draw_text 0, 0, @contents.width, LINE_H,
                            "#{title}  [#{id_label(first)}-#{id_label(last)}]"
        (0...PAGE_SIZE).each do |i|
          id = first + i
          break if id > max_id
          y = (i + 1) * LINE_H
          @contents.draw_text 0, y, NAME_COL_W, LINE_H, "#{id_label(id)}:#{row_name(id)}"
          @contents.draw_text NAME_COL_W, y, @contents.width - NAME_COL_W, LINE_H,
                              row_value_text(id), 2
        end
        @window.cursor_rect = Rect.new(0, (@cursor + 1) * LINE_H, @contents.width, LINE_H)
      end

      # -- Variable value editor, opened by C on a Variable row ----------------

      # 999,999 (RPG2000) / 9,999,999 (RPG2003) -- Game::Variables::MAX/MIN
      # vs. RPG2003_MAX/MIN (`mruby-rpg2k/mrblib/game.rb`), the same
      # edition-gated range EasyRPG's own `Game_Variables::GetMaxDigits`
      # derives its debug-menu editor width from (`src/scene_debug.cpp`
      # sizes and drives its `Window_NumberInput` straight off it) --
      # a flat 6-digit editor structurally cannot enter or display an
      # RPG2003 variable's own top decade.
      EDITOR_DIGITS_2K = 6
      EDITOR_DIGITS_2K3 = 7

      # The effective digit width for this state's own database edition. A
      # bare test double with no #rpg2003? of its own reads false, matching
      # a genuine RPG2000 database (the same guard Game::Actor#rpg2003?/
      # Game::Party#rpg2003? already use for their own @db).
      def editor_digits
        rpg2003 = @state.party.respond_to?(:rpg2003?) && @state.party.rpg2003?
        rpg2003 ? EDITOR_DIGITS_2K3 : EDITOR_DIGITS_2K
      end

      def open_editor(id)
        v = @state.variables[id]
        @editor = { id: id, negative: v.negative?, digits: digits_of(v.abs), cursor: 0 }
        build_editor_window
      end

      # #editor_digits-long digit array (most significant first) for a
      # non-negative value, e.g. digits_of(7) -> [0, 0, 0, 0, 0, 7]. No
      # String#chars/#rjust here, for the same reason as #id_label above.
      def digits_of(value)
        n = editor_digits
        ds = Array.new(n, 0)
        (n - 1).downto(0) do |i|
          ds[i] = value % 10
          value /= 10
        end
        ds
      end

      def editor_value
        v = @editor[:digits].reduce(0) { |a, d| a * 10 + d }
        @editor[:negative] ? -v : v
      end

      def build_editor_window
        w = (editor_digits + 1) * 12 + Window::BORDER * 2
        h = LINE_H + Window::BORDER * 2
        @editor_window = Window.new((SCREEN_W - w) / 2, (SCREEN_H - h) / 2, w, h)
        @editor_window.z = 410
        @editor_window.windowskin = @skin
        @editor_contents = Bitmap.new(w - Window::BORDER * 2, LINE_H)
        @editor_window.contents = @editor_contents
        refresh_editor
      end

      def refresh_editor
        c = @editor_contents
        c.clear
        c.font.color = Color.new(255, 255, 255, 255)
        sign = @editor[:negative] ? '-' : '+'
        c.draw_text 0, 0, c.width, LINE_H, sign + @editor[:digits].join, 1
      end

      def update_editor
        cells = editor_digits + 1 # the sign occupies cell 0, digits follow
        if Input.trigger?(Input::B)
          close_editor
        elsif Input.trigger?(Input::C)
          @state.variables[@editor[:id]] = editor_value
          close_editor
          refresh
        elsif Input.trigger?(Input::LEFT)
          @editor[:cursor] -= 1 if @editor[:cursor].positive?
        elsif Input.trigger?(Input::RIGHT)
          @editor[:cursor] += 1 if @editor[:cursor] < cells - 1
        elsif Input.trigger?(Input::UP) || Input.trigger?(Input::DOWN)
          up = Input.trigger?(Input::UP)
          if @editor[:cursor].zero?
            @editor[:negative] = !@editor[:negative]
          else
            di = @editor[:cursor] - 1
            @editor[:digits][di] = (@editor[:digits][di] + (up ? 1 : 9)) % 10
          end
        end
        refresh_editor if @editor
      end

      def close_editor
        return unless @editor
        @editor_window.dispose if @editor_window
        @editor_window = nil
        @editor_contents = nil
        @editor = nil
      end
    end
  end
end
