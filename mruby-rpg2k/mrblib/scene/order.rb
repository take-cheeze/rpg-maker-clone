class RPG2k
  module Scene
    # The field Order screen (RPG2003 main menu -> Order, System chunk 22 field
    # 27's `menu_commands` id 7). Reorders the party front-to-back, and it is a
    # *pick-and-place* build, not a swap or a drag-drop. The left column lists
    # the current party in its existing order; the player picks members one at
    # a time (DOWN/UP to move, C to pick), and each pick is appended to the
    # right column in the order picked -- the eventual front-to-back order. A
    # picked member's name disappears from the left column (the row stays, and
    # stays selectable, but picking it again does nothing) so the player always
    # sees who is left. Cancel undoes the most recent pick one at a time, or
    # leaves the screen once nothing is picked yet. Once every member has been
    # picked, a Confirm/Redo prompt takes over: Confirm applies the new order
    # and closes the screen, Redo (or Cancel here) clears every pick and starts
    # over. Reordering can change the party leader outright --
    # `Game::Party#leader` is simply `@actors.first`.
    #
    # **Measured at last, against a genuine RPG2003 `RPG_RT.EXE` under wine
    # (cycle #256, 2026-09-06)**, closing what cycle #251 recorded as blocked.
    # The block was never "2003 renders nothing here" in general -- it was
    # *Song-of-the-Sea's* binary specifically. kk1.12's own `RPG_RT.EXE` boots
    # and renders fine (title, map, field menu, every sub-screen), but its
    # database's `menu_commands` is `[1, 2, 5, 3, 6, 8, 4]` with no Order in
    # it, so the way in was to copy kk1.12 into a scratch directory and rewrite
    # *that copy's* `RPG_RT.ldb` System chunk 22 field 27 to
    # `[1, 2, 5, 3, 6, 8, 4, 7]` (field 26, the count, to 8) through this
    # project's own LCF writer -- no game data of the checkout was touched, and
    # nothing but that one array changed. The genuine runtime then drew a real
    # Order row (blank-labelled: kk1.12's `order` term is the empty string) and
    # opened the screen below, on a three-member party resumed from a save the
    # game itself wrote. Every geometry number here is halved from a 640x480
    # capture of that session; each behavioural claim names the frame pair that
    # shows it. The two SE claims (#pick_current's rejected re-pick, #redo's
    # cancel sound) remain unconfirmed -- the reference X server has no audio,
    # so no capture can settle them -- and a one-or-fewer-member party's buzzer
    # (`Scene::Menu#select_command`'s Order gate) is likewise still unmeasured,
    # since shrinking a genuine save's party list blackens RPG_RT on Continue.
    #
    # The screen draws over the field menu's own backdrop, not one of its own:
    # the uncovered area of every Order capture is a uniform (0,0,24), which is
    # exactly kk1.12's System graphic pixel (0,32) -- (0,2,30) -- under the
    # reference X server's RGB565 quantisation, i.e. the colour
    # `Scene::Base#build_field_background` already fills the screen with for
    # the parent `Scene::Menu` (whose own windows `Scene::Menu#suspend` hides
    # while this screen is up).
    class Order < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # The two list columns, measured from their window borders' own bounding
      # boxes: left (68, 48, 88, 80) and right (164, 48, 88, 80) -- 88 wide
      # each with an 8px gap, the pair centred horizontally (68 of margin on
      # each side of 88+8+88 = 184).
      COLUMN_W = 88
      COLUMN_GAP = 8
      LIST_X = (SCREEN_W - COLUMN_W * 2 - COLUMN_GAP) / 2
      LIST_Y = 48
      # Both list windows are 80 tall on a *three*-member party -- four 16px
      # rows plus the 8px border twice -- so they are sized for RPG2003's
      # four-member maximum rather than for the party actually present (the
      # fourth row simply stays empty, and the cursor never reaches it: UP from
      # the first row wrapped to the third, not the fourth). A four-member
      # party was not available to tell this apart from a `size * 16 + 32`
      # sizing that happens to agree at three; see docs/TODO.md.
      MAX_PARTY_ROWS = 4
      LIST_H = MAX_PARTY_ROWS * LINE_H + Window::BORDER * 2
      # The Confirm/Redo prompt: (120, 144, 80, 48), horizontally centred,
      # two 16px rows plus the border.
      CONFIRM_W = 80
      CONFIRM_Y = 144
      # RPG_RT's own (Japanese runtime) wording for the prompt -- see
      # #build_windows.
      CONFIRM_LABEL = '決定'.freeze
      REDO_LABEL = 'やりなおし'.freeze

      # bc2cpp: (, Game::State)
      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @names = @state.party.actors.map { |a| a.name.to_s }
        @picked = Array.new(@names.size)   # original index picked into slot i, or nil
        @counter = 0
        @cursor_index = 0
        @confirm_index = 0
        @focus = :left
        build_windows
      end

      def dispose
        @left_window.dispose if @left_window
        @right_window.dispose if @right_window
        @confirm_window.dispose if @confirm_window
      end

      def update
        # Every live window needs its own #update called every frame to
        # advance its selection-cursor blink (RPG2k::Window#update) -- this
        # scene never called it at all, the same gap Scene::Menu's own
        # #update had (see its own citation).
        @left_window.update if @left_window
        @right_window.update if @right_window
        @confirm_window.update if @confirm_window
        @focus == :confirm ? update_confirm : update_left
      end

      private

      # Holding Down/Up auto-repeats both cursors here after the initial
      # delay, not just a single step per tap -- ported from a reference
      # implementation's source, NOT independently confirmed against
      # genuine RPG_RT under wine: its own scene update calls both the left
      # and confirm windows' update unconditionally, every frame, before
      # ever checking which one is active -- both are standard
      # selectable-list windows, whose own update is what actually drives
      # the cursor (trigger-then-repeat, see
      # `Scene::ItemMenu#update_items`'s fuller writeup); the active check
      # only gates the *Decision/Cancel* handling, not the cursor movement
      # itself.
      def update_left
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @counter == 0 ? @parent.pop : undo_last_pick
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_cursor(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_cursor(-1)
        elsif Input.trigger?(Input::C)
          pick_current
        end
      end
      # bc2cpp: (fixnum)

      def move_cursor(delta)
        @cursor_index += delta
        @cursor_index %= @names.size
        refresh_left_cursor
        play_system_se(SFX_CURSOR)
      end

      # Reject re-picking an already-picked slot (its left-column text is
      # blank, but the row is still there to land the cursor on) with the
      # Cancel SE, ported from a reference implementation's source and NOT
      # independently confirmed against genuine RPG_RT under wine -- that
      # implementation's own duplicate-pick guard plays the same SE as a
      # rejected-but-confirmed choice elsewhere in this menu (matching
      # #choose_item/#choose_skill's Buzzer precedent would be a different,
      # unconfirmed SE).
      def pick_current
        if @picked.include?(@cursor_index)
          play_system_se(SFX_CANCEL)
          return
        end
        play_system_se(SFX_DECISION)
        @picked[@counter] = @cursor_index
        @counter += 1
        refresh_left_window
        refresh_right_window
        enter_confirm if @counter == @names.size
      end

      def undo_last_pick
        @counter -= 1
        @picked[@counter] = nil
        refresh_left_window
        refresh_right_window
      end

      # Ported from a reference implementation's source, NOT independently
      # confirmed against genuine RPG_RT under wine: once the last member is
      # picked, it clears the left window's cursor index before deactivating
      # it -- distinct from simply going inactive (see
      # `RPG2k::Window#draw_cursor`'s own "freeze, don't hide" fix, which
      # still applies to every *other* inactive window whose index is
      # untouched). That implementation's own cursor-rect update
      # special-cases a negative index to an empty rect, emptying the
      # highlight outright -- so this ported model hides the left column's
      # cursor entirely at this transition rather than freezing it on the
      # now-blank final row.
      def enter_confirm
        @focus = :confirm
        @confirm_index = 0
        @left_window.active = false
        @left_window.cursor_rect = Rect.new(0, 0, 0, 0)
        @confirm_window.visible = true
        @confirm_window.active = true
        refresh_confirm_cursor
      end

      # Matches a reference implementation's own confirm-update handler, NOT
      # independently confirmed against genuine RPG_RT under wine: Cancel and
      # choosing "Redo" both
      # funnel into #redo, whose own Cancel SE plays regardless of which input
      # triggered it -- Decision on "Confirm" is the only path with its own SE.
      def update_confirm
        if Input.trigger?(Input::B)
          redo_picks
        elsif Input.trigger?(Input::DOWN) || Input.trigger?(Input::UP) ||
              Input.repeat?(Input::DOWN) || Input.repeat?(Input::UP)
          @confirm_index = @confirm_index == 0 ? 1 : 0
          refresh_confirm_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          @confirm_index == 0 ? confirm_order : redo_picks
        end
      end

      def confirm_order
        play_system_se(SFX_DECISION)
        @state.party.reorder(@picked.compact)
        @parent.pop
      end

      def redo_picks
        play_system_se(SFX_CANCEL)
        @picked = Array.new(@names.size)
        @counter = 0
        @cursor_index = 0
        refresh_left_window
        refresh_right_window
        @left_window.active = true
        @confirm_window.visible = false
        @confirm_window.active = false
        @focus = :left
        refresh_left_cursor
      end

      def build_windows
        @left_window = Window.new(LIST_X, LIST_Y, COLUMN_W, LIST_H)
        @left_window.z = 400
        @left_window.windowskin = @skin
        @right_window = Window.new(LIST_X + COLUMN_W + COLUMN_GAP, LIST_Y,
                                   COLUMN_W, LIST_H)
        @right_window.z = 400
        @right_window.windowskin = @skin
        refresh_left_window
        refresh_right_window
        refresh_left_cursor

        # The prompt's two labels have no slot of their own in RPG2000/2003's
        # Term table (schema.rb's Terms carry nothing of the sort, and
        # kk1.12's own table has no such string), so RPG_RT draws them itself:
        # the Japanese runtime's own wording, measured on the genuine frame, is
        # 決定 / やりなおし.
        labels = [CONFIRM_LABEL, REDO_LABEL]
        ch = labels.size * LINE_H + Window::BORDER * 2
        @confirm_window = Window.new((SCREEN_W - CONFIRM_W) / 2, CONFIRM_Y,
                                     CONFIRM_W, ch)
        @confirm_window.z = 450
        @confirm_window.windowskin = @skin
        cc = Bitmap.new(CONFIRM_W - Window::BORDER * 2, labels.size * LINE_H)
        cc.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |l, i|
          draw_system_text cc, 0, i * LINE_H, cc.width, LINE_H, l, @skin
        end
        @confirm_window.contents = cc
        @confirm_window.visible = false
        @confirm_window.active = false
      end

      def refresh_left_window
        inner_w = COLUMN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, @names.size * LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        @names.each_with_index do |name, i|
          next if @picked.include?(i)
          draw_system_text c, 0, i * LINE_H, inner_w, LINE_H, name, @skin
        end
        @left_window.contents = c
      end

      def refresh_right_window
        inner_w = COLUMN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, @names.size * LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        @picked.each_with_index do |orig, i|
          next unless orig
          draw_system_text c, 0, i * LINE_H, inner_w, LINE_H, @names[orig], @skin
        end
        @right_window.contents = c
      end

      def refresh_left_cursor
        @left_window.cursor_rect =
          Rect.new(0, @cursor_index * LINE_H, @left_window.contents.width, LINE_H)
      end

      def refresh_confirm_cursor
        @confirm_window.cursor_rect =
          Rect.new(0, @confirm_index * LINE_H, @confirm_window.contents.width, LINE_H)
      end
    end

  end
end
