class RPG2k
  module Scene
    # The field item screen (main menu -> Item). Lists the party's usable
    # medicines with their held counts; picking one either applies it to the
    # whole party (an all-ally item) or asks which ally to use it on (a
    # single-target item). Using an item consumes one and refreshes the list; an
    # item that would have no effect (everyone already full) is reported and not
    # consumed. A special item invoking an Escape or Teleport skill warps the
    # party instead, the same as Scene::SkillMenu's own Escape/Teleport skills:
    # Escape jumps straight to its one registered target, Teleport opens a
    # picker of every registered destination, and either closes the whole menu
    # stack rather than showing a "Used on ..." message. All decision logic
    # lives in Game::Party (field_items / use_item / item_effective? /
    # use_special_escape_item / use_special_teleport_item), which the host
    # harnesses test; this class is the RGSS UI over it, mirroring
    # Scene::Menu's window/cursor/message helpers.
    class ItemMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

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
        build_item_window
      end

      def dispose
        close_message
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
          @parent.pop
        elsif Input.trigger?(Input::DOWN) && !items.empty?
          @item_index += 1
          @item_index %= items.size
          refresh_item_cursor
        elsif Input.trigger?(Input::UP) && !items.empty?
          @item_index -= 1
          @item_index %= items.size
          refresh_item_cursor
        elsif Input.trigger?(Input::C)
          choose_item
        end
      end

      def choose_item
        return if items.empty?
        id, = items[@item_index]
        it = @state.party.db_item(id)
        # A switch item has no actor target; an all-ally medicine skips the
        # target prompt; single-target medicines / skill books ask who to use on.
        # A special item follows the *skill* it invokes, since that is what
        # decides the scope — self (2) or all-ally (4) needs no prompt.
        if it && it.type == Game::Party::ITEM_SWITCH
          apply_switch_item(id)
        elsif it && it.type == Game::Party::ITEM_SPECIAL
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
      end

      # A switch item turns on its game switch (the party consumes one); the menu
      # owns the switch table.
      def apply_switch_item(id)
        sid = @state.party.use_switch_item(id)
        @state.switches[sid] = true if sid
        show_message(sid ? "Switch turned on." : "It had no effect.", :used)
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
          leave_teleport_target
        elsif Input.trigger?(Input::DOWN) && !targets.empty?
          @teleport_index += 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
        elsif Input.trigger?(Input::UP) && !targets.empty?
          @teleport_index -= 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
        elsif Input.trigger?(Input::C) && !targets.empty?
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
          leave_target_mode
        elsif Input.trigger?(Input::DOWN)
          @target_index += 1
          @target_index %= party.size
          refresh_target_cursor
        elsif Input.trigger?(Input::UP)
          @target_index -= 1
          @target_index %= party.size
          refresh_target_cursor
        elsif Input.trigger?(Input::C)
          apply_item(@pending_item, party[@target_index])
        end
      end

      def apply_item(id, actor)
        affected = @state.party.use_item(id, actor)
        if affected.empty?
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

      def build_item_window
        @item_window.dispose if @item_window
        rows = items
        inner_w = SCREEN_W - Window::BORDER * 2
        h = [rows.size, 1].max * LINE_H
        @item_window = Window.new(0, 0, SCREEN_W, h + Window::BORDER * 2)
        @item_window.z = 400
        @item_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 2, inner_w, LINE_H, "No items"
        else
          rows.each_with_index do |(id, count), i|
            it = @state.party.db_item(id)
            name = (it && it.name.to_s)
            name = "Item #{id}" if name.nil? || name.empty?
            c.draw_text 0, i * LINE_H + 2, inner_w - 40, LINE_H, name
            c.draw_text inner_w - 40, i * LINE_H + 2, 40, LINE_H, ":#{count}"
          end
        end
        @item_window.contents = c
        refresh_item_cursor
      end

      def refresh_item_cursor
        return unless @item_window
        h = items.empty? ? 0 : LINE_H
        @item_window.cursor_rect =
          Rect.new(0, @item_index * LINE_H, @item_window.contents.width, h)
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
