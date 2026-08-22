class RPG2k
  module Scene
    # RPG_RT's F9 debug menu (see Scene::Map#try_open_debug_menu -- Test Play
    # only, opened from the field map).
    #
    # The Switch/Variable pages are two genuine RPG_RT pages, and their own
    # navigation was directly re-verified against real RPG_RT.exe under wine
    # for this fix (a prior version of this file guessed a single flat,
    # one-level list -- wrong on every axis below). RPG_RT draws them as
    # *two* borderless-gap, edge-to-edge windows side by side, flush with the
    # screen: a LEFT_W-wide left window listing SCREEN_BLOCKS "blocks" of
    # BLOCK_SIZE ids each (e.g. "S[ 0041-0050 ]"), and a right window
    # previewing the ten individual ids of whichever block is highlighted --
    # confirmed by editing a genuine Nepheshel save's switch table and
    # reading back real RPG_RT.exe screenshots, not by inspecting any other
    # engine's source. Two independent cursor/focus levels, not one:
    #   * Block focus (the default on opening, and after B backs out of row
    #     focus): Up/Down moves the highlighted block by +-1, *wrapping*
    #     within the current screen's ten blocks (block 9 + Down -> block 0,
    #     same screen -- verified directly, holding Up from block 0 landed on
    #     block 9 without changing the id range shown). Left/Right instead
    #     pages the whole screen by a full SCREEN_SIZE (=BLOCK_SIZE *
    #     SCREEN_BLOCKS) ids, *preserving* the highlighted block's index
    #     (verified: highlighting block index 3, then Right, landed on block
    #     index 3 of the next screen, not index 0). C enters row focus on the
    #     highlighted block, always starting at its first row. Holding Down
    #     visibly outran a single-tap's one-block move (auto-repeat, the same
    #     trigger-then-repeat convention every other confirmed list cursor in
    #     this codebase already follows -- see item_menu.rb/skill_menu.rb).
    #   * Row focus: Up/Down moves the row cursor by +-1 among the
    #     highlighted block's own BLOCK_SIZE ids, wrapping locally (row 9 +
    #     Down -> row 0 of the *same* block -- verified directly; it does not
    #     cross into the neighbouring block). Left/Right do nothing here
    #     (verified). C acts on the selected row (toggle a switch instantly,
    #     confirmed OFF->ON on a real save; or open the signed number editor
    #     for a variable, unchanged from before this fix). B returns to block
    #     focus without closing the menu; a second B (now in block focus)
    #     closes it, matching the two real Escape presses this was verified
    #     with (open -> row focus -> block focus -> closed).
    # What actually cycles a genuine RPG_RT install between just these two
    # pages was not identified -- Left/Right, Q/W (this codebase's own L/R
    # keys), PageUp/PageDown, Tab, Shift, Space, and a dozen more all left the
    # Switch page showing Switch, so it is not asserted here.
    #
    # Map, Chipset and Animation (this codebase's own additions -- not part
    # of genuine RPG_RT's F9 menu at all, so nothing above constrains them)
    # keep their pre-existing single-panel look and their own Up/Down
    # +-1/L/R +-10 id stepping, C opening the relevant tool, unchanged by
    # this fix; Left/Right still cycles between all five pages on these
    # three, exactly as before. Switch/Variable can no longer use Left/Right
    # to cycle -- that input means screen-paging there now, confirmed above
    # -- so they cycle on L/R (shoulder) instead, which is otherwise unused
    # on those two pages. Both bindings are purely this engine's own
    # tooling wiring for a five-page menu real RPG_RT never had (only
    # Switch/Variable are genuine), not an RPG_RT fidelity claim.
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
      MODES = [:switch, :variable, :map, :chipset, :animation].freeze

      # Switch/Variable page geometry, measured directly off real RPG_RT.exe
      # screenshots (a 640x480 2x-scaled capture, halved back to the game's
      # native 320x240): two windows flush to the screen edges, y=32..208
      # (height (BLOCK_SIZE * LINE_H) + Window::BORDER*2 = 176, no title
      # row -- the block labels are the left window's own ten rows, there is
      # no separate header), left window x=0..96, right window x=96..320.
      BLOCK_SIZE = 10
      SCREEN_BLOCKS = 10
      SCREEN_SIZE = BLOCK_SIZE * SCREEN_BLOCKS
      LEFT_W = 96
      SW_TOP = 32

      def initialize(parent, state)
        super parent
        @state = state
        @skin = make_windowskin
        @background = build_field_background(@skin)
        @mode = :switch
        @page = 0
        @block = 0
        @row = 0
        @focus = :block
        @anim_id = 1
        # The Map page's own selected id -- defaults to the player's actual
        # current map (so C still opens straight onto it unchanged, same as
        # before this existed), but Up/Down/L/R (see #update_map_page) can
        # step it to browse and open any other map's Scene::MapViewer instead.
        @map_id = @state.map ? @state.map.id : 1
        @editor = nil
        build_window
      end

      def dispose
        close_editor
        @background.dispose if @background
        @window.dispose if @window
        @left_window.dispose if @left_window
        @right_window.dispose if @right_window
      end

      def update
        return update_editor if @editor
        case @mode
        when :map then update_map_page
        when :chipset then update_chipset_page
        when :animation then update_animation
        else update_switch_or_variable
        end
      end

      private

      # Block/row focus (see the class comment) for the two genuine RPG_RT
      # pages.
      def update_switch_or_variable
        @focus == :row ? update_row_focus : update_block_focus
      end

      def update_block_focus
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_block(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_block(-1)
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          turn_page(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          turn_page(-1)
        elsif Input.trigger?(Input::L)
          cycle_mode(-1)
        elsif Input.trigger?(Input::R)
          cycle_mode(1)
        elsif Input.trigger?(Input::C)
          enter_row_focus
        end
      end

      def update_row_focus
        if Input.trigger?(Input::B)
          @focus = :block
          refresh
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_row(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_row(-1)
        elsif Input.trigger?(Input::C)
          activate_row
        end
      end

      # Chipset has no id of its own to step, so unlike Map/Animation below it
      # has no L/R stepping to avoid clashing with -- cycles on Left/Right
      # the same as Map/Animation do, for one consistent "how do I flip
      # between these three invented pages" answer across all three.
      def update_chipset_page
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::RIGHT)
          cycle_mode(1)
        elsif Input.trigger?(Input::LEFT)
          cycle_mode(-1)
        elsif Input.trigger?(Input::C)
          activate_row
        end
      end

      def cycle_mode(delta)
        idx = (MODES.index(@mode) + delta) % MODES.length
        @mode = MODES[idx]
        @page = 0
        @block = 0
        @row = 0
        @focus = :block
        refresh
      end

      def max_page
        (max_id - 1) / SCREEN_SIZE
      end

      def move_block(delta)
        @block = (@block + delta) % SCREEN_BLOCKS
        refresh
      end

      def move_row(delta)
        @row = (@row + delta) % BLOCK_SIZE
        refresh
      end

      def enter_row_focus
        @focus = :row
        @row = 0
        refresh
      end

      def turn_page(delta)
        p = @page + delta
        return if p.negative? || p > max_page
        @page = p
        refresh
      end

      def current_id
        @page * SCREEN_SIZE + @block * BLOCK_SIZE + @row + 1
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

      def update_animation
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::RIGHT)
          cycle_mode(1)
        elsif Input.trigger?(Input::LEFT)
          cycle_mode(-1)
        elsif Input.trigger?(Input::C)
          play_animation
        elsif Input.trigger?(Input::UP) || Input.trigger?(Input::DOWN)
          @anim_id = [@anim_id + (Input.trigger?(Input::UP) ? 1 : -1), 1].max
          refresh
        elsif Input.trigger?(Input::R) || Input.trigger?(Input::L)
          @anim_id = [@anim_id + (Input.trigger?(Input::R) ? 10 : -10), 1].max
          refresh
        end
      end

      # Same Up/Down +-1, L/R +-10 stepping #update_animation uses for
      # @anim_id (Left/Right cycle pages instead, so neither page can use
      # them for its own id) -- C opens the selected @map_id's
      # Scene::MapViewer rather than always the player's own current map, the
      # way plain C used to before @map_id existed.
      def update_map_page
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::RIGHT)
          cycle_mode(1)
        elsif Input.trigger?(Input::LEFT)
          cycle_mode(-1)
        elsif Input.trigger?(Input::C)
          activate_row
        elsif Input.trigger?(Input::UP) || Input.trigger?(Input::DOWN)
          @map_id = [@map_id + (Input.trigger?(Input::UP) ? 1 : -1), 1].max
          refresh
        elsif Input.trigger?(Input::R) || Input.trigger?(Input::L)
          @map_id = [@map_id + (Input.trigger?(Input::R) ? 10 : -10), 1].max
          refresh
        end
      end

      # Play @anim_id back on the live field map, screen-centred, the same way
      # Scene::Battle#start_battle_animation fires one mid-fight -- through
      # Scene::Map's own public animation-player API (see its "reached from
      # Scene::ChipsetEditor"/battle-callback `public` blocks), reached via
      # RPG2k#map_scene since this menu itself only has @state, not the live
      # map scene. Closes the whole debug menu (#pop_to_map) so the animation
      # is what's on screen next, the same way opening the Map Editor's
      # teleport does.
      def play_animation
        scene = @parent.respond_to?(:map_scene) ? @parent.map_scene : nil
        return unless scene.respond_to?(:build_animation)
        target = scene.anim_target(SCREEN_W / 2, SCREEN_H / 2, height: nil, index: nil,
                                                                flash_target: nil)
        scene.map_animation = scene.build_animation(@anim_id, [target], true)
        @parent.pop_to_map
      end

      def activate_row
        if @mode == :map
          open_map_viewer
          return
        elsif @mode == :chipset
          @parent.push Scene::ChipsetEditor.new(@parent, @state)
          return
        end
        id = current_id
        if @mode == :switch
          @state.switches[id] = !@state.switches[id]
          refresh
        else
          open_editor(id)
        end
      end

      # Opens @map_id's Scene::MapViewer -- the player's own live map (unchanged
      # from before @map_id existed) when it's the id selected, or any other
      # map loaded fresh off disk via RPG2k#load_map otherwise, so a project
      # can be browsed and edited one map at a time without first walking the
      # player there. A load failure (a map with no id, or no such .lmu file
      # yet) is reported and simply doesn't open anything, the same way a
      # broken chipset load in Scene::MapViewer itself degrades rather than
      # raising into the debug menu.
      def open_map_viewer
        if @state.map && @map_id == @state.map.id
          @parent.push Scene::MapViewer.new(@parent, @state, map: @state.map)
          return
        end
        map = begin
          @parent.load_map(@map_id)
        rescue StandardError => e
          $stderr.puts "[RPG2k] map ##{@map_id} could not be loaded: #{e.message}"
          nil
        end
        return unless map
        @parent.push Scene::MapViewer.new(@parent, @state, map: map)
      end

      def row_name(id)
        table = @mode == :switch ? db.switch : db.variable
        row = table && table[id]
        name = row && row.respond_to?(:name) ? row.name : nil
        name.nil? ? '' : name
      end

      # RPG_RT draws a Switch row's value bracketed -- "[ ON ]"/"[ OFF ]",
      # confirmed directly off the same real RPG_RT.exe screenshots the
      # block/row navigation above was verified against. A Variable row's
      # own value format was not independently confirmed (this session never
      # got real RPG_RT onto the Variable page -- see the class comment), so
      # it stays exactly as it already was rather than guessing the bracket
      # applies there too.
      def row_value_text(id)
        return @state.variables[id].to_s unless @mode == :switch
        "[ #{@state.switches[id] ? 'ON' : 'OFF'} ]"
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

        # The two genuine RPG_RT pages: see the class comment for how this
        # geometry and the block/row split were measured.
        sh = BLOCK_SIZE * LINE_H + Window::BORDER * 2
        @left_window = Window.new(0, SW_TOP, LEFT_W, sh)
        @left_window.z = 400
        @left_window.windowskin = @skin
        @left_contents = Bitmap.new(LEFT_W - Window::BORDER * 2, BLOCK_SIZE * LINE_H)
        @left_window.contents = @left_contents

        rw = SCREEN_W - LEFT_W
        @right_window = Window.new(LEFT_W, SW_TOP, rw, sh)
        @right_window.z = 400
        @right_window.windowskin = @skin
        @right_contents = Bitmap.new(rw - Window::BORDER * 2, BLOCK_SIZE * LINE_H)
        @right_window.contents = @right_contents

        refresh
      end

      def refresh
        return unless @contents
        switch_or_variable = @mode == :switch || @mode == :variable
        @window.visible = !switch_or_variable
        @left_window.visible = switch_or_variable
        @right_window.visible = switch_or_variable
        return refresh_switch_or_variable if switch_or_variable
        @contents.clear
        @contents.font.color = Color.new(255, 255, 255, 255)
        return refresh_map_page if @mode == :map
        return refresh_chipset_page if @mode == :chipset
        refresh_animation_page
      end

      # Two windows, two cursors -- see the class comment for the real
      # RPG_RT behaviour this reproduces. The left cursor stays drawn (on
      # the highlighted block) in both focus states, exactly as measured;
      # the right cursor is empty in block focus and shows the row only once
      # row focus is entered.
      def refresh_switch_or_variable
        @left_contents.clear
        @right_contents.clear
        @left_contents.font.color = Color.new(255, 255, 255, 255)
        @right_contents.font.color = Color.new(255, 255, 255, 255)
        prefix = @mode == :switch ? 'S' : 'V'
        screen_first = @page * SCREEN_SIZE + 1
        (0...SCREEN_BLOCKS).each do |b|
          block_first = screen_first + b * BLOCK_SIZE
          break if block_first > max_id
          block_last = [block_first + BLOCK_SIZE - 1, max_id].min
          y = b * LINE_H
          label = "#{prefix}[ #{id_label(block_first)}-#{id_label(block_last)} ]"
          @left_contents.draw_text 0, y, @left_contents.width, LINE_H, label
        end
        block_first = screen_first + @block * BLOCK_SIZE
        (0...BLOCK_SIZE).each do |r|
          id = block_first + r
          break if id > max_id
          y = r * LINE_H
          @right_contents.draw_text 0, y, NAME_COL_W, LINE_H, "#{id_label(id)}:#{row_name(id)}"
          @right_contents.draw_text NAME_COL_W, y, @right_contents.width - NAME_COL_W, LINE_H,
                                    row_value_text(id), 2
        end
        @left_window.cursor_rect = Rect.new(0, @block * LINE_H, @left_contents.width, LINE_H)
        @right_window.cursor_rect = if @focus == :row
                                       Rect.new(0, @row * LINE_H, @right_contents.width, LINE_H)
                                     else
                                       Rect.new(0, 0, 0, 0)
                                     end
      end

      # No row list to select from, so no cursor bar either -- clear whatever
      # the Switch/Variable pages last left behind.
      def refresh_map_page
        @window.cursor_rect = Rect.new(0, 0, 0, 0)
        @contents.draw_text 0, 0, @contents.width, LINE_H, 'Map'
        info = @state.map ? "Current: Map #{@state.map.id}  #{@state.map.width}x#{@state.map.height}  " \
                            "x:#{@state.x} y:#{@state.y}" : 'No map loaded'
        @contents.draw_text 0, LINE_H, @contents.width, LINE_H, info
        select_line = "Selected: ##{@map_id} #{map_name(@map_id)}"
        @contents.draw_text 0, LINE_H * 2, @contents.width, LINE_H, select_line
        hint = 'Up/Down:+-1  L/R:+-10  C:Open'
        @contents.draw_text 0, LINE_H * 3, @contents.width, LINE_H, hint
      end

      # Same respond_to?/nil-guarded lookup #animation_name uses, so a bare
      # test fixture with no map_tree at all (or one with no map_properties
      # chunk) stays silent and only a genuine dangling id gets its own
      # "(not found)".
      def map_name(id)
        return '' unless @map_tree.respond_to?(:map_properties) && @map_tree.map_properties
        row = @map_tree.map_properties[id]
        row && row.respond_to?(:name) ? row.name : '(not found)'
      end

      def refresh_chipset_page
        @window.cursor_rect = Rect.new(0, 0, 0, 0)
        @contents.draw_text 0, 0, @contents.width, LINE_H, 'Chipset'
        id = @state.map ? @state.map.chipset_id : 1
        @contents.draw_text 0, LINE_H, @contents.width, LINE_H, "Current map's chipset: ##{id}"
        @contents.draw_text 0, LINE_H * 2, @contents.width, LINE_H, 'C: open chipset editor'
      end

      def refresh_animation_page
        @window.cursor_rect = Rect.new(0, 0, 0, 0)
        @contents.draw_text 0, 0, @contents.width, LINE_H, 'Animation'
        id_line = "##{@anim_id} #{animation_name(@anim_id)}"
        @contents.draw_text 0, LINE_H, @contents.width, LINE_H, id_line
        hint = 'Up/Down:+-1  L/R:+-10  C:Play'
        @contents.draw_text 0, LINE_H * 2, @contents.width, LINE_H, hint
      end

      # Same respond_to?/nil-guarded lookup Scene::Map#animation_row uses, so
      # a bare test fixture with no battle_anime table at all stays silent and
      # only a genuine dangling id gets its own "(not found)".
      def animation_name(id)
        return '' unless db.respond_to?(:battle_anime) && db.battle_anime
        row = db.battle_anime[id]
        row && row.respond_to?(:name) ? row.name : '(not found)'
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
