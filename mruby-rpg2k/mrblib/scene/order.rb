class RPG2k
  module Scene
    # The field Order screen (RPG2003 main menu -> Order, System chunk 22 field
    # 27's `menu_commands` id 7). Reorders the party front-to-back -- ported
    # from a reference implementation's own order scene, NOT independently
    # confirmed against genuine RPG_RT under wine: it is a *pick-and-place*
    # build, not a swap or a drag-drop. The left column lists the current
    # party in its existing order; the player picks members one at a time
    # (DOWN/UP to move, C to pick), and each pick is appended to the right
    # column in the order picked -- the eventual front-to-back order. A
    # picked member's name disappears from the left column (but the row
    # stays selectable and picking it again is rejected with the Cancel SE,
    # that reference implementation's own already-picked guard) so the
    # player always sees who is left. Cancel undoes
    # the most recent pick one at a time, or leaves the screen once nothing is
    # picked yet. Once every member has been picked, a Confirm/Redo prompt
    # takes over (`window_confirm`): Confirm applies the new order and closes
    # the screen, Redo (or Cancel here) clears every pick and starts over.
    # Reordering can change the party leader outright -- `Game::Party#leader`
    # is simply `@actors.first` -- exactly like genuine RPG_RT.
    class Order < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # Width of the left (current order) and right (picked order) columns,
      # and of the Confirm/Redo prompt below them.
      COLUMN_W = 96

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
        h = @names.size * LINE_H + Window::BORDER * 2
        @left_window = Window.new(20, 20, COLUMN_W, h)
        @left_window.z = 400
        @left_window.windowskin = @skin
        @right_window = Window.new(20 + COLUMN_W, 20, COLUMN_W, h)
        @right_window.z = 400
        @right_window.windowskin = @skin
        refresh_left_window
        refresh_right_window
        refresh_left_cursor

        # "Confirm"/"Redo" have no slot of their own in RPG2000/2003's Term
        # table -- a reference implementation only gained translatable
        # fields for them as its own extension, which this schema (modelled
        # on genuine RPG_RT's own chunk layout) does not carry, so these
        # stay plain English same as genuine RPG_RT itself.
        labels = ['Confirm', 'Redo']
        ch = labels.size * LINE_H + Window::BORDER * 2
        @confirm_window = Window.new((SCREEN_W - COLUMN_W) / 2, SCREEN_H - ch - 20, COLUMN_W, ch)
        @confirm_window.z = 450
        @confirm_window.windowskin = @skin
        cc = Bitmap.new(COLUMN_W - Window::BORDER * 2, labels.size * LINE_H)
        cc.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index { |l, i| cc.draw_text 0, i * LINE_H, cc.width, LINE_H, l }
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
          c.draw_text 0, i * LINE_H, inner_w, LINE_H, name
        end
        @left_window.contents = c
      end

      def refresh_right_window
        inner_w = COLUMN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, @names.size * LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        @picked.each_with_index do |orig, i|
          next unless orig
          c.draw_text 0, i * LINE_H, inner_w, LINE_H, @names[orig]
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
