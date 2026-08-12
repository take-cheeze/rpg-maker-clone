class RPG2k
  module Scene
    # The field equip screen (main menu -> Equip). Shows one party member's five
    # equipment slots and current stats; LEFT/RIGHT cycle the member. Choosing a
    # slot lists the bag's items that fit it (plus Remove); choosing one equips it
    # -- swapping the previously-worn item back into the bag -- or empties the
    # slot. The bag-aware equip logic is Game::Party#equip_candidates /
    # equip_from_bag / unequip_to_bag (host-tested); this is the RGSS UI over it,
    # mirroring Scene::ItemMenu's helpers. A two-handed weapon empties the other
    # hand (Actor#free_two_handed_slot) and a 二刀流 actor's shield slot lists
    # weapons instead of shields (#equip_candidates, given `actor`) -- both
    # handled by the party-level logic this scene just calls through to.
    class EquipMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = 0
        @slot_index = 0
        @cand_index = 0
        @mode = :slots          # :slots list, or :items candidate pick
        @slots = [
          term(:weapon, "Weapon"), term(:shield, "Shield"), term(:armor, "Armor"),
          term(:helmet, "Helmet"), term(:accessory, "Accessory")
        ]
        build_stats_window
        build_slot_window
      end

      def dispose
        @stats_window.dispose if @stats_window
        @slot_window.dispose if @slot_window
        @cand_window.dispose if @cand_window
      end

      def update
        @mode == :items ? update_items : update_slots
      end

      private

      def actor
        @state.party.actors[@actor_index]
      end

      def item_name(id)
        return "-" if id.nil? || id == 0
        it = @state.party.db_item(id)
        n = it && it.name.to_s
        n.nil? || n.empty? ? "Item #{id}" : n
      end

      def update_slots
        party = @state.party.actors
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::DOWN)
          @slot_index += 1
          @slot_index %= @slots.size
          refresh_slot_cursor
        elsif Input.trigger?(Input::UP)
          @slot_index -= 1
          @slot_index %= @slots.size
          refresh_slot_cursor
        elsif Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          rebuild_for_actor
        elsif Input.trigger?(Input::LEFT)
          @actor_index -= 1
          @actor_index %= party.size
          rebuild_for_actor
        elsif Input.trigger?(Input::C)
          @cand_index = 0
          @mode = :items
          build_cand_window
        end
      end

      def candidates
        # The slot's fitting bag items, with a leading Remove entry (id 0). A
        # 二刀流 actor's shield slot lists weapons instead of shields, which is
        # why `actor` goes along -- see Game::Party#equip_candidates.
        @candidates ||= [[0, 0]] + @state.party.equip_candidates(@slot_index, actor)
      end

      def update_items
        if Input.trigger?(Input::B)
          leave_items
        elsif Input.trigger?(Input::DOWN)
          @cand_index += 1
          @cand_index %= candidates.size
          refresh_cand_cursor
        elsif Input.trigger?(Input::UP)
          @cand_index -= 1
          @cand_index %= candidates.size
          refresh_cand_cursor
        elsif Input.trigger?(Input::C)
          apply_choice
        end
      end

      def apply_choice
        id, = candidates[@cand_index]
        if id == 0
          @state.party.unequip_to_bag(actor, @slot_index)
        else
          # Pass the slot the candidate list was built for -- a 二刀流 actor's
          # second weapon has to land in the shield slot (1), which its own
          # item type (weapon, slot 0) would not otherwise pick.
          @state.party.equip_from_bag(actor, id, @slot_index)
        end
        leave_items
        rebuild_for_actor
      end

      def leave_items
        @candidates = nil
        @mode = :slots
        if @cand_window
          @cand_window.dispose
          @cand_window = nil
        end
      end

      def rebuild_for_actor
        @slot_index = @slots.size - 1 if @slot_index >= @slots.size
        build_stats_window
        build_slot_window
      end

      def build_stats_window
        @stats_window.dispose if @stats_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = LINE_H * 3
        @stats_window = Window.new(0, 0, SCREEN_W, h + Window::BORDER * 2)
        @stats_window.z = 400
        @stats_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = actor
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}  #{term(:level_short, 'Lv')} #{a.level}"
        c.draw_text 0, LINE_H, inner_w, LINE_H,
                    "#{term(:hp_short, 'HP')} #{a.hp}/#{a.max_hp}  " \
                    "#{term(:mp_short, 'MP')} #{a.mp}/#{a.max_mp}"
        c.draw_text 0, LINE_H * 2, inner_w, LINE_H,
                    "#{term(:attack, 'Atk')} #{a.atk}  #{term(:defense, 'Def')} #{a.def}  " \
                    "#{term(:mind, 'Int')} #{a.int}  #{term(:agility, 'Agi')} #{a.agi}"
        @stats_window.contents = c
      end

      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = @slots.size * LINE_H
        y = LINE_H * 3 + Window::BORDER * 2
        @slot_window = Window.new(0, y, SCREEN_W, h + Window::BORDER * 2)
        @slot_window.z = 400
        @slot_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        eq = actor.equipment
        @slots.each_with_index do |label, i|
          c.draw_text 0, i * LINE_H, 80, LINE_H, label
          c.draw_text 80, i * LINE_H, inner_w - 80, LINE_H, item_name(eq[i])
        end
        @slot_window.contents = c
        refresh_slot_cursor
      end

      def refresh_slot_cursor
        return unless @slot_window
        @slot_window.cursor_rect =
          Rect.new(0, @slot_index * LINE_H, @slot_window.contents.width, LINE_H)
      end

      def build_cand_window
        @cand_window.dispose if @cand_window
        rows = candidates
        inner_w = SCREEN_W - Window::BORDER * 2
        h = rows.size * LINE_H
        @cand_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                  SCREEN_W, h + Window::BORDER * 2)
        @cand_window.z = 450
        @cand_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.each_with_index do |(id, count), i|
          if id == 0
            c.draw_text 0, i * LINE_H, inner_w, LINE_H, "(Remove)"
          else
            c.draw_text 0, i * LINE_H, inner_w - 40, LINE_H, item_name(id)
            c.draw_text inner_w - 40, i * LINE_H, 40, LINE_H, ":#{count}"
          end
        end
        @cand_window.contents = c
        refresh_cand_cursor
      end

      def refresh_cand_cursor
        return unless @cand_window
        @cand_window.cursor_rect =
          Rect.new(0, @cand_index * LINE_H, @cand_window.contents.width, LINE_H)
      end
    end

  end
end
