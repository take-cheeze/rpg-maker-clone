class RPG2k
  module Scene
    # The field item screen (main menu -> Item). Lists the party's usable
    # medicines with their held counts; picking one either applies it to the
    # whole party (an all-ally item) or asks which ally to use it on (a
    # single-target item). Using an item consumes one and refreshes the list; an
    # item that would have no effect (everyone already full) is reported and not
    # consumed. A switch item instead flips its game switch and closes the
    # whole menu stack outright, with no "Used on ..." message -- the same as
    # a special item invoking an Escape or Teleport skill, which warps the
    # party instead, the same as Scene::SkillMenu's own Escape/Teleport skills:
    # Escape jumps straight to its one registered target, Teleport opens a
    # picker of every registered destination. All decision logic lives in
    # Game::Party (field_items / use_item / use_switch_item / item_effective? /
    # use_special_escape_item / use_special_teleport_item), which the host
    # harnesses test; this class is the RGSS UI over it, mirroring
    # Scene::Menu's window/cursor/message helpers.
    class ItemMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # Height of the item-description banner at the very top of the screen
      # (see #build_desc_window) -- mirrors Scene::EquipMenu's own banner,
      # which the item list is offset down by.
      DESC_H = LINE_H + Window::BORDER * 2

      # The item list is a two-column grid, not a single stacked column --
      # confirmed against genuine RPG_RT under wine with a five-item bag,
      # which filled row-major (item 0 top-left, item 1 top-right, item 2
      # second row left, ...) and left an incomplete last row's second cell
      # blank rather than reflowing. Cursor movement is grid-aware and does
      # not wrap at an edge (EasyRPG's own Window_Selectable::CursorDown/Up/
      # Right/Left shape, `cycle` off): DOWN/UP move by COLUMN_MAX and are a
      # no-op with no cell below/above (tried pressing DOWN off the last,
      # partial row -- the cursor simply stayed), RIGHT/LEFT move by one and
      # are a no-op at the row's own edge.
      COLUMN_MAX = 2

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @mode = :items          # :items list, :target selection, or :teleport_target
        @item_index = 0
        @target_index = 0
        @teleport_index = 0
        @pending_item = nil
        @message = nil
        build_desc_window
        build_item_window
      end

      def dispose
        close_message
        @desc_window.dispose if @desc_window
        @item_window.dispose if @item_window
        @target_window.dispose if @target_window
        @teleport_window.dispose if @teleport_window
      end

      def update
        return drive_message if @message
        case @mode
        when :target then update_target
        when :teleport_target then update_teleport_target
        else update_items
        end
      end

      private

      # Cached list of [id, count] pairs; invalidated after a use changes counts.
      # `@state` decides whether a special item invoking an Escape/Teleport
      # skill belongs in it (see Game::Party#field_items).
      def items
        @items ||= @state.party.field_items(@state)
      end

      def invalidate_items
        @items = nil
      end

      def update_items
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN)
          move_item_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP)
          move_item_cursor(-COLUMN_MAX)
        elsif Input.trigger?(Input::RIGHT)
          move_item_cursor(1) if (@item_index + 1) % COLUMN_MAX != 0
        elsif Input.trigger?(Input::LEFT)
          move_item_cursor(-1) if @item_index % COLUMN_MAX != 0
        elsif Input.trigger?(Input::C)
          choose_item
        end
      end

      # Move the item cursor by `delta` cells (a row for +-COLUMN_MAX, a
      # column for +-1), ignored if that cell is off the grid -- confirmed
      # against genuine RPG_RT under wine, which leaves the cursor put
      # rather than wrapping (see the COLUMN_MAX comment above).
      def move_item_cursor(delta)
        return if items.empty?
        target = @item_index + delta
        return if target < 0 || target >= items.size
        @item_index = target
        refresh_item_cursor
        play_system_se(SFX_CURSOR)
      end

      def choose_item
        if items.empty?
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        id, = items[@item_index]
        it = @state.party.db_item(id)
        # A switch item has no actor target; an all-ally medicine skips the
        # target prompt; single-target medicines / skill books ask who to use on.
        # A special item follows the *skill* it invokes, since that is what
        # decides the scope — self (2) or all-ally (4) needs no prompt.
        if it && it.type == Game::Party::ITEM_SWITCH
          apply_switch_item(id)
        elsif it && (it.type == Game::Party::ITEM_SPECIAL ||
                    (it.use_skill && (1..5).cover?(it.type)))
          # A type-9 special item, or an equipment item flagged `use_skill`
          # (schema field 71), both invoke the skill named in `skill_id`: the
          # invoked skill's type/scope decides the dispatch, so a self (2) or
          # all-ally (4) skill needs no target prompt and an Escape/Teleport
          # skill warps. Mirrors the special-item path exactly (see the
          # type-9 fixes above); an equipment item simply reaches the same
          # `#use_equip_skill_item` / `#use_special_escape_item` /
          # `#use_special_teleport_item` backing as it already does for an
          # ordinary targeted cast.
          sk = @state.party.db_skill(it.skill_id)
          if sk && sk.type == Game::Party::SKILL_ESCAPE
            # Escape has one registered target and no picker -- mirroring
            # Scene::SkillMenu#apply_escape_skill, a successful cast warps
            # straight there with no confirmation message.
            apply_escape_item(id)
          elsif sk && sk.type == Game::Party::SKILL_TELEPORT
            # Teleport opens a third list of every registered destination, the
            # same as Scene::SkillMenu's own teleport picker.
            @pending_item = id
            @mode = :teleport_target
            @teleport_index = 0
            build_teleport_window
            refresh_desc
          elsif sk && (sk.scope == 2 || sk.scope == 4)
            # Unlike a medicine (whose all-ally scope needs no actor at all --
            # #use_medicine reads the whole party off `@actors`, ignoring the
            # argument), a special item's `actor` argument is the *caster*
            # #use_special_item casts the skill from (mirroring
            # Scene::SkillMenu, which always has a caster selected). Passing
            # nil here left every self/all-ally special item uncastable
            # through this menu -- #use_special_item's own `return [] unless
            # actor` guard rejected it before the skill's scope ever mattered.
            apply_item(id, @state.party.leader)
          else
            prompt_item_target(id)
          end
        elsif it && it.scope == 1 && it.type == Game::Party::ITEM_MEDICINE
          apply_item(id, nil)
        else
          prompt_item_target(id)
        end
      end

      # Ask which party member the pending item is used on.
      def prompt_item_target(id)
        @pending_item = id
        @mode = :target
        @target_index = 0
        build_target_window
        refresh_desc
      end

      # A switch item turns on its game switch (the menu owns the switch table)
      # and consumes one -- then closes the whole menu stack at once, the same
      # as a special item invoking Escape or Teleport (RPG_RT never leaves a
      # switch item's user sitting in the item list afterwards, since flipping
      # a switch is typically what a waiting map event is watching for). No
      # confirmation message on success, matching that same Escape/Teleport
      # precedent; a use that consumed nothing (not actually a held switch
      # item) reports "It had no effect." and stays put instead.
      def apply_switch_item(id)
        sid = @state.party.use_switch_item(id)
        if sid
          @state.switches[sid] = true
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # A special item invoking an Escape-type skill: cast from the party
      # leader (mirroring the self/all-ally special-item branch above), free.
      # A successful cast closes the whole menu stack at once, matching
      # Scene::SkillMenu#apply_escape_skill -- there is no field-menu message
      # shown afterwards, since the map that would show it is gone before the
      # next frame draws.
      def apply_escape_item(id)
        target = @state.party.use_special_escape_item(id, @state.party.leader, @state)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # The same for a Teleport-type skill, once a destination is chosen from
      # the list built by #build_teleport_window.
      def apply_teleport_item(id, map_id)
        target = @state.party.use_special_teleport_item(id, @state.party.leader, @state, map_id)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # Queue the warp for Scene::Map (see Game::State#pending_teleport) and pop
      # every menu on top of it in one step -- the same shape
      # Scene::SkillMenu#queue_teleport uses.
      def queue_teleport(target)
        @state.pending_teleport = [target[:map_id], target[:x], target[:y], 0]
        @parent.pop_to_map
      end

      def update_teleport_target
        targets = teleport_targets
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_teleport_target
        elsif Input.trigger?(Input::DOWN) && !targets.empty?
          @teleport_index += 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) && !targets.empty?
          @teleport_index -= 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C) && !targets.empty?
          play_system_se(SFX_DECISION)
          map_id, = targets[@teleport_index]
          apply_teleport_item(@pending_item, map_id)
        end
      end

      def leave_teleport_target
        @pending_item = nil
        @mode = :items
        if @teleport_window
          @teleport_window.dispose
          @teleport_window = nil
        end
        refresh_desc
      end

      # The registered teleport destinations as `[map_id, name]` pairs,
      # ascending by map id -- see Scene::SkillMenu#teleport_targets, which
      # this mirrors exactly.
      def teleport_targets
        @state.teleport_targets.keys.sort.map { |id| [id, map_display_name(id)] }
      end

      # A map's editor name for the teleport picker, or its bare id when the
      # tree carries no name for it -- see Scene::SkillMenu#map_display_name.
      def map_display_name(map_id)
        row = map_tree.respond_to?(:map_properties) ? map_tree.map_properties[map_id] : nil
        name = row && row.respond_to?(:name) ? row.name.to_s : nil
        name.nil? || name.empty? ? "Map #{map_id}" : name
      end

      def build_teleport_window
        @teleport_window.dispose if @teleport_window
        rows = teleport_targets
        inner_w = SCREEN_W - Window::BORDER * 2
        h = [rows.size, 1].max * LINE_H
        @teleport_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                      SCREEN_W, h + Window::BORDER * 2)
        @teleport_window.z = 450
        @teleport_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 0, inner_w, LINE_H, "No destinations"
        else
          rows.each_with_index do |(_id, name), i|
            c.draw_text 0, i * LINE_H, inner_w, LINE_H, name
          end
        end
        @teleport_window.contents = c
        refresh_teleport_cursor
      end

      def refresh_teleport_cursor
        return unless @teleport_window
        h = teleport_targets.empty? ? 0 : LINE_H
        @teleport_window.cursor_rect =
          Rect.new(0, @teleport_index * LINE_H, @teleport_window.contents.width, h)
      end

      def update_target
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_target_mode
        elsif Input.trigger?(Input::DOWN)
          @target_index += 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP)
          @target_index -= 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          apply_item(@pending_item, party[@target_index])
        end
      end

      # A used item that changed nothing (everyone already full, an
      # ineffective status cure, ...) plays Buzzer rather than a second
      # Decision -- matching RPG_RT's own invalid-use handling elsewhere in
      # `Scene_Item` (a rejected action gets the same SE as a confirm on an
      # empty list or a disabled command, not a silent no-op).
      def apply_item(id, actor)
        affected = @state.party.use_item(id, actor)
        if affected.empty?
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        else
          names = affected.map { |a| a.name.to_s }.join(", ")
          show_message("Used on #{names}.", :used)
        end
      end

      def leave_target_mode
        @pending_item = nil
        @mode = :items
        if @target_window
          @target_window.dispose
          @target_window = nil
        end
        refresh_desc
      end

      # After a successful use, drop back to the item list and rebuild it (the
      # count fell, and a depleted item leaves the list). Keeps the cursor in
      # range when the last item is used up.
      def refresh_after_use
        leave_target_mode
        invalidate_items
        @item_index = items.size - 1 if @item_index >= items.size
        @item_index = 0 if @item_index < 0
        build_item_window
      end

      # The highlighted item's flavour text, in a one-line banner across the
      # very top of the screen -- confirmed against genuine RPG_RT under
      # wine (e.g. "HPを80ポイント程度回復する" for a healing item), the same
      # gap Scene::EquipMenu had. Tracks the item under the cursor in :items
      # mode; the :target/:teleport_target pickers keep showing the pending
      # item's own description, since it is still the one thing on screen a
      # description could be about.
      def build_desc_window
        @desc_window.dispose if @desc_window
        inner_w = SCREEN_W - Window::BORDER * 2
        @desc_window = Window.new(0, 0, SCREEN_W, DESC_H)
        @desc_window.z = 400
        @desc_window.windowskin = @skin
        @desc_contents = Bitmap.new(inner_w, LINE_H)
        @desc_window.contents = @desc_contents
        refresh_desc
      end

      def refresh_desc
        return unless @desc_contents
        id = if @mode == :items
               rows = items
               rows.empty? ? nil : rows[@item_index].first
             else
               @pending_item
             end
        it = id && id != 0 ? @state.party.db_item(id) : nil
        text = it ? it.description.to_s : ''
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      # Column width for the item grid (see the COLUMN_MAX comment above).
      def item_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      def build_item_window
        @item_window.dispose if @item_window
        rows = items
        inner_w = SCREEN_W - Window::BORDER * 2
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = grid_rows * LINE_H
        @item_window = Window.new(0, DESC_H, SCREEN_W, h + Window::BORDER * 2)
        @item_window.z = 400
        @item_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        col_w = item_col_w
        # An empty bag draws no placeholder text -- confirmed against genuine
        # RPG_RT under wine, which shows a blank list row (still with a
        # visible, empty cursor box; see #refresh_item_cursor) rather than
        # any "no items" message.
        rows.each_with_index do |(id, count), i|
          it = @state.party.db_item(id)
          name = (it && it.name.to_s)
          name = "Item #{id}" if name.nil? || name.empty?
          x = (i % COLUMN_MAX) * col_w
          y = (i / COLUMN_MAX) * LINE_H
          c.draw_text x, y + 2, col_w - 40, LINE_H, name
          c.draw_text x + col_w - 40, y + 2, 40, LINE_H, ":#{count}"
        end
        @item_window.contents = c
        refresh_item_cursor
      end

      def refresh_item_cursor
        return unless @item_window
        # The cursor box stays visible on the empty row even with no items --
        # matched against genuine RPG_RT under wine, which highlights the
        # blank slot rather than hiding the cursor. It highlights just the
        # one grid cell, not the full row -- confirmed by the same captures
        # that found the grid layout itself (see the COLUMN_MAX comment).
        x = (@item_index % COLUMN_MAX) * item_col_w
        y = (@item_index / COLUMN_MAX) * LINE_H
        @item_window.cursor_rect = Rect.new(x, y, item_col_w, LINE_H)
        refresh_desc
      end

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = SCREEN_W - Window::BORDER * 2
        h = party.size * (LINE_H * 2)
        @target_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                    SCREEN_W, h + Window::BORDER * 2)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        party.each_with_index do |a, i|
          y = i * LINE_H * 2
          c.draw_text 0, y, inner_w, LINE_H, a.name.to_s
          # RPG_RT's target list shows each member's condition (its
          # Window_ActorTarget draws one) -- which is most of the point of the
          # list, since it is where you pick who to use an antidote on.
          draw_actor_state c, a, 0, y, inner_w, LINE_H, @skin, 2
          c.draw_text 0, y + LINE_H, inner_w, LINE_H,
                      "#{term(:hp_short, 'HP')} #{a.hp}/#{a.max_hp}  " \
                      "#{term(:mp_short, 'MP')} #{a.mp}/#{a.max_mp}"
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      def refresh_target_cursor
        return unless @target_window
        @target_window.cursor_rect =
          Rect.new(0, @target_index * LINE_H * 2, @target_window.contents.width,
                   LINE_H * 2)
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        # A successful use drops back to the (rebuilt) item list; a no-effect use
        # stays in the current mode so the player can pick another target/item.
        refresh_after_use if done == :used
      end

      def show_message(text, done = nil)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win, done: done }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

  end
end
