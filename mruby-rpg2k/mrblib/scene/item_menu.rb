class RPG2k
  module Scene
    # The field item screen (main menu -> Item). Lists the party's usable
    # medicines with their held counts; picking one either applies it to the
    # whole party (an all-ally item) or asks which ally to use it on (a
    # single-target item). Using an item consumes one and refreshes the list; an
    # item that would have no effect (everyone already full) is reported and not
    # consumed. All decision logic lives in Game::Party (field_items / use_item /
    # item_effective?), which the host harnesses test; this class is the RGSS UI
    # over it, mirroring Scene::Menu's window/cursor/message helpers.
    class ItemMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @mode = :items          # :items list, or :target selection
        @item_index = 0
        @target_index = 0
        @pending_item = nil
        @message = nil
        build_item_window
      end

      def dispose
        close_message
        @item_window.dispose if @item_window
        @target_window.dispose if @target_window
      end

      def update
        return drive_message if @message
        @mode == :target ? update_target : update_items
      end

      private

      # Cached list of [id, count] pairs; invalidated after a use changes counts.
      def items
        @items ||= @state.party.field_items
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
          if sk && (sk.scope == 2 || sk.scope == 4)
            apply_item(id, nil)
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
