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

      # Height of the item-description banner at the very top of the screen
      # (see #build_desc_window) -- the stats/slot/candidate windows below it
      # are all offset down by this much.
      DESC_H = LINE_H + Window::BORDER * 2

      # `actor_index` is which party member the screen opens on -- the one
      # `Scene::Menu#enter_actor_selection` preselected from the menu's own
      # party list (confirmed against EasyRPG's `Scene_Equip` constructor,
      # which takes the same parameter), defaulting to 0 (the leader) for
      # callers that never had a picker to begin with, e.g. the host test
      # harnesses. LEFT/RIGHT still cycle from there once inside, unlike
      # Scene::SkillMenu -- EasyRPG's own `Scene_Equip::UpdateEquipSelection`
      # does the same, unlike `Scene_Skill`.
      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = actor_index
        @slot_index = 0
        @cand_index = 0
        @mode = :slots          # :slots list, or :items candidate pick
        @warned_missing_item_ids = {}
        @slots = [
          term(:weapon, "Weapon"), term(:shield, "Shield"), term(:armor, "Armor"),
          term(:helmet, "Helmet"), term(:accessory, "Accessory")
        ]
        build_desc_window
        build_stats_window
        build_slot_window
      end

      def dispose
        @desc_window.dispose if @desc_window
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
        if it.nil?
          warn_missing_item(id)
          return "Item #{id}"
        end
        n = it.name.to_s
        n.empty? ? "Item #{id}" : n
      end

      # #item_name's diagnostic for an equipped slot whose item id has no
      # database row -- the "item" case from docs/TODO.md's runtime error
      # catalog's dangling-id list (a database shrink leaving a stale
      # reference behind), on this screen's equipped-slot *display* path
      # rather than the field/battle Item-menu's inventory-*list*-filtering
      # one (a separate fix). The placeholder label is unchanged; this is
      # diagnostics only. Deduped per id for the scene's lifetime --
      # #item_name reruns every time the slot/candidate windows rebuild
      # (every LEFT/RIGHT actor switch), and logging each of those for an
      # id that never resolves would spam the console for as long as the
      # screen stays open.
      def warn_missing_item(id)
        return if @warned_missing_item_ids[id]
        @warned_missing_item_ids[id] = true
        $stderr.puts "[RPG2k] Equip screen: item ##{id} not found in the " \
                     "database, showing a placeholder label"
      end

      # The slot cursor (DOWN/UP) auto-repeats while held -- it lives on a
      # genuine `Window_Equip`, a `Window_Selectable` subclass, whose own
      # `Update()` falls through to `Input::IsRepeated` the same as every
      # other list here (see Scene::ItemMenu#update_items's fuller
      # writeup). The actor switch (RIGHT/LEFT) does **not**: confirmed
      # against EasyRPG's actual source -- `Scene_Equip::
      # UpdateEquipSelection` (`src/scene_equip.cpp`) checks
      # `Input::IsTriggered(Input::RIGHT/LEFT)` only, no `IsRepeated` at
      # all, since each switch pushes a whole new `Scene_Equip` rather than
      # moving a cursor within one -- left as a discrete-only, one-tap
      # action, unlike the DOWN/UP slot cursor right beside it.
      def update_slots
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @slot_index += 1
          @slot_index %= @slots.size
          refresh_slot_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @slot_index -= 1
          @slot_index %= @slots.size
          refresh_slot_cursor
          play_system_se(SFX_CURSOR)
        # A solo party leaves RIGHT/LEFT silent no-ops -- confirmed against
        # RPG_RT's own live source: `Scene_Equip::UpdateEquipSelection`
        # (`src/scene_equip.cpp`) gates both branches on `actors.size() >
        # 1`, not just the trigger itself, so a lone hero's Equip screen
        # plays no cursor SE and rebuilds nothing on either key.
        elsif party.size > 1 && Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          rebuild_for_actor
          play_system_se(SFX_CURSOR)
        elsif party.size > 1 && Input.trigger?(Input::LEFT)
          @actor_index -= 1
          @actor_index %= party.size
          rebuild_for_actor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          # 装備固定 / 呪われた装備: RPG_RT refuses to even open the item list
          # for such an actor, or for a slot currently holding a cursed item
          # (EasyRPG's Scene_Equip#UpdateEquipSelection), rather than opening
          # it and rejecting whatever gets chosen there -- confirmed a
          # rejected Decision plays Buzzer, matching every other "confirmed
          # but refused" case this scene's siblings handle the same way.
          if actor.equipment_fixed? || actor.slot_cursed?(@slot_index)
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @cand_index = 0
            @mode = :items
            build_cand_window
          end
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
          play_system_se(SFX_CANCEL)
          leave_items
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @cand_index += 1
          @cand_index %= candidates.size
          refresh_cand_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @cand_index -= 1
          @cand_index %= candidates.size
          refresh_cand_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
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
        refresh_desc
      end

      def rebuild_for_actor
        @slot_index = @slots.size - 1 if @slot_index >= @slots.size
        build_stats_window
        build_slot_window
      end

      # The highlighted item's flavour text, in a one-line banner across the
      # very top of the screen -- confirmed against genuine RPG_RT under
      # wine, which shows the database item's own `description` field there
      # (e.g. a weapon's "[斬光風龍神]イリスの想いを宿す時の剣"); this scene
      # drew no such banner at all. Tracks whichever item is currently under
      # the cursor: the slot's own equipped item in :slots mode, or the
      # highlighted candidate in :items mode (blank for the leading Remove
      # entry and for an empty slot, matching there being no item to
      # describe).
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
        id = @mode == :items ? candidates[@cand_index].first : actor.equipment[@slot_index]
        it = id && id != 0 ? @state.party.db_item(id) : nil
        text = it ? it.description.to_s : ''
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      def build_stats_window
        @stats_window.dispose if @stats_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = LINE_H * 3
        @stats_window = Window.new(0, DESC_H, SCREEN_W, h + Window::BORDER * 2)
        @stats_window.z = 400
        @stats_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = actor
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}  #{term(:level_short, 'Lv')} #{a.level}"
        c.draw_text 0, LINE_H, inner_w, LINE_H,
                    "#{term(:hp_short, 'HP')} #{a.hp}/#{a.display_max_hp}  " \
                    "#{term(:mp_short, 'MP')} #{a.mp}/#{a.display_max_mp}"
        c.draw_text 0, LINE_H * 2, inner_w, LINE_H,
                    "#{term(:attack, 'Atk')} #{a.atk}  #{term(:defense, 'Def')} #{a.def}  " \
                    "#{term(:mind, 'Int')} #{a.int}  #{term(:agility, 'Agi')} #{a.agi}"
        @stats_window.contents = c
      end

      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = @slots.size * LINE_H
        y = DESC_H + LINE_H * 3 + Window::BORDER * 2
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
        refresh_desc
      end

      # yado.tk: the equip-list comparison arrow is the *sum* of all four
      # combat-stat deltas between a candidate and whatever currently
      # occupies the slot, not four separate per-stat verdicts -- a weapon
      # that trades -2 Atk for +3 Def still draws a single Up arrow (net +1),
      # never a mixed per-stat readout. The four fields are RPG2000's own
      # "points1" equip-bonus set (`Game::Actor::EQUIP_BONUS_FIELD`'s combat
      # quarter -- max HP/SP have no comparison arrow, only the four battle
      # stats do).
      STAT_POINT_FIELDS = [:atk_points1, :def_points1, :spi_points1, :agi_points1].freeze

      # The summed equip-bonus points of item `id` (0 for an empty slot, a
      # missing database row, or a fixture item lacking these fields).
      def item_stat_sum(id)
        return 0 if id.nil? || id == 0
        row = @state.party.db_item(id)
        return 0 unless row
        STAT_POINT_FIELDS.reduce(0) do |s, f|
          s + ((row.respond_to?(f) ? row.send(f) : nil) || 0)
        end
      end

      # '^' the candidate's combined stat points beat what is equipped now,
      # 'v' it falls short, '-' the two are equal (RPG_RT draws small
      # triangle icons here; plain glyphs stand in since this build has no
      # icon-cell blit for them yet).
      def equip_compare_arrow(delta)
        return '^' if delta > 0
        return 'v' if delta < 0
        '-'
      end

      # The other hand's own current item id when browsing the weapon (0) or
      # shield (1) slot -- the only two slots a 両手持ち weapon can force off
      # -- or nil for any other slot. Mirrors `Actor#free_two_handed_slot`'s
      # own `slot == WEAPON_SLOT || slot == SHIELD_SLOT` gate.
      def other_hand_item
        case @slot_index
        when Game::Actor::WEAPON_SLOT then actor.equipment[Game::Actor::SHIELD_SLOT]
        when Game::Actor::SHIELD_SLOT then actor.equipment[Game::Actor::WEAPON_SLOT]
        end
      end

      # The candidate's real net stat-point delta against what is equipped
      # now -- not just the two items landing in *this* slot. Confirmed
      # against EasyRPG's actual C++ source: `Scene_Equip::
      # UpdateStatusWindow` (`src/scene_equip.cpp`) also subtracts the
      # *other* hand's item when either it or the candidate is a 両手持ち
      # weapon (`Actor#two_handed?`), since equipping either one forces the
      # opposite slot empty -- the exact side effect `Actor#equip_item` /
      # `#free_two_handed_slot` already applies for real, which this preview
      # ignored (id 0, "Remove", never triggers it either way, matching
      # EasyRPG's own `current_item &&` guard -- removing an item never
      # forces anything off the other hand).
      def equip_delta(id)
        delta = item_stat_sum(id) - item_stat_sum(actor.equipment[@slot_index])
        other = other_hand_item
        if id != 0 && other && (actor.two_handed?(other) || actor.two_handed?(id))
          delta -= item_stat_sum(other)
        end
        delta
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
            c.draw_text 0, i * LINE_H, inner_w - 80, LINE_H, item_name(id)
            c.draw_text inner_w - 80, i * LINE_H, 40, LINE_H,
                        equip_compare_arrow(equip_delta(id))
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
        refresh_desc
      end
    end

  end
end
