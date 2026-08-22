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
        # A solo party leaves RIGHT/LEFT silent no-ops -- this was only ever
        # cited to EasyRPG's own live source (`Scene_Equip::
        # UpdateEquipSelection`, `src/scene_equip.cpp`, gating both branches
        # on `actors.size() > 1`), the exact kind of claim this session's
        # methodology treats as worth re-checking on its own. Independently
        # re-verified since (cycle #121) against a genuine RPG_RT.exe under
        # wine: with a solo-actor party on the real Equip screen, a single
        # RIGHT tap followed by a single LEFT tap left the captured frame
        # pixel-identical (0 differing pixels, `compare -fuzz 5%`) to a pair
        # of idle frames sampled the same distance apart with no key pressed
        # at all -- the only pixel movement anywhere in the sequence was the
        # windowskin's own constant cursor-blink noise floor (a steady 3200
        # px, present between every frame pair regardless of input), not a
        # rebuilt screen or a moved actor. Confirmed correct; no code change.
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
            build_cand_window # rebuilds the stats window's preview too, via #refresh_cand_cursor
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
        build_stats_window
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
        h = LINE_H * (1 + STAT_DEFS.size)
        @stats_window = Window.new(0, DESC_H, SCREEN_W, h + Window::BORDER * 2)
        @stats_window.z = 400
        @stats_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = actor
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}  #{term(:level_short, 'Lv')} #{a.level}"
        draw_stat_row(c, a)
        @stats_window.contents = c
      end

      # RPG2000 term / equip-bonus field / actor-accessor / effective-stat
      # method / state-flag quintuples for the four battle stats, in the
      # order EasyRPG's own `Window_EquipStatus::DrawParameter`
      # (`src/window_equipstatus.cpp`) draws them (Atk/Def/Spirit/Agility --
      # this codebase's own `term(:mind, ...)`/`#int` name RPG2000's
      # "Spirit" stat "Int" instead, matching status_menu.rb).
      STAT_DEFS = [
        [:attack, 'Atk', :atk_points1, :atk, :effective_atk, :affect_attack],
        [:defense, 'Def', :def_points1, :def, :effective_def, :affect_defense],
        [:mind, 'Int', :spi_points1, :int, :effective_int, :affect_spirit],
        [:agility, 'Agi', :agi_points1, :agi, :effective_agi, :affect_agility]
      ].freeze

      # Four independent stat rows -- one "label value" per row while
      # browsing the slot list, or, while browsing candidates, "label value
      # > new_value" comparisons -- confirmed against EasyRPG's actual
      # `Window_EquipStatus::Refresh`/`DrawParameter`
      # (`src/window_equipstatus.cpp`), which draws the actor name once,
      # then loops the four stats at `y_offset + ((12 + 4) * i)` -- a
      # genuinely separate row per stat, each an old value, an arrow, and a
      # new value coloured by `GetNewParameterColor` (0 unchanged / 2 up / 3
      # down), never a single combined verdict for the whole item (see
      # #build_cand_window's own history for the summed-arrow this
      # replaced) and never sharing a row with any other stat.
      def draw_stat_row(c, a)
        previewing = @mode == :items
        cand_id = previewing ? candidates[@cand_index].first : nil
        STAT_DEFS.each_with_index do |(term_key, label, field, accessor,
                                        effective_method, stat_flag), i|
          y = LINE_H * (1 + i)
          x = 0
          # State-adjusted (halve/double), not the raw base+equip total --
          # confirmed against RPG_RT's own live source: `Window_EquipStatus::
          # DrawParameter` (`src/window_equipstatus.cpp`) draws
          # `actor.GetAtk()` et al., which run the base value through
          # `Game_Battler::AdjustParam` (`src/game_battler.cpp`) against
          # whatever states the actor currently carries. `Game::Party
          # #effective_atk`/`#effective_def`/`#effective_int`/`#effective_agi`
          # already port this (built for skill formulas); this screen never
          # called them.
          value = @state.party.send(effective_method, a)
          text = "#{term(term_key, label)} #{value}"
          c.font.color = Color.new(255, 255, 255, 255)
          w = c.text_size(text).width
          c.draw_text x, y, w, LINE_H, text
          x += w
          if previewing
            # The preview recomputes the new *base* total (this stat's own
            # raw base+equip accessor plus the candidate's raw point delta,
            # matching `#effective_atk` et al.'s own base+equip reading)
            # and only then reapplies the state halve/double, exactly
            # mirroring `Scene_Equip::UpdateStatusWindow` (`src/
            # scene_equip.cpp`): it rebuilds `atk`/`def`/`spi`/`agi` from
            # `GetBaseAtk(..., equip: false)` plus each equipped item's own
            # point field, clamps, then calls
            # `actor.CalcValueAfterAtkStates(atk)` -- the state adjustment
            # is the last step, not folded additively into the raw delta.
            delta = stat_field_delta(cand_id, field)
            # Clamped to 1..999 (`Game::Actor::MAX_EFFECTIVE_STAT`, matching
            # `scene_equip.cpp`'s own `actor.MaxStatBaseValue()`) *before*
            # the state adjustment -- the reference's `Utils::Clamp(atk, 1,
            # limit)` runs ahead of `CalcValueAfterAtkStates`, not after.
            new_base = Game.clamp(a.send(accessor) + delta, 1,
                                   Game::Actor::MAX_EFFECTIVE_STAT)
            new_value = @state.party.adjust_stat(
              new_base, @state.party.stat_mode(a, stat_flag)
            )
            arrow_w = c.text_size('>').width
            draw_system_text c, x, y, arrow_w, LINE_H, '>', @skin, 1
            x += arrow_w
            new_text = new_value.to_s
            new_w = c.text_size(new_text).width
            # `Window_EquipStatus::GetNewParameterColor` (same file) compares
            # the two *displayed* (state-adjusted) values, not the raw item
            # delta's sign -- the two usually agree, but only this matches
            # the reference at a clamp boundary or under a halving state.
            color_idx = new_value == value ? 0 : (new_value > value ? 2 : 3)
            draw_system_text c, x, y, new_w, LINE_H, new_text, @skin, color_idx
          end
        end
      end

      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = @slots.size * LINE_H
        y = DESC_H + LINE_H * (1 + STAT_DEFS.size) + Window::BORDER * 2
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

      # RPG2000's own "points1" equip-bonus set (`Game::Actor::
      # EQUIP_BONUS_FIELD`'s combat quarter -- max HP/SP have no comparison
      # preview, only the four battle stats do), in `STAT_DEFS`' own order.
      STAT_POINT_FIELDS = [:atk_points1, :def_points1, :spi_points1, :agi_points1].freeze

      # Item `id`'s raw `field` value (0 for an empty slot, a missing
      # database row, or a fixture item lacking the field).
      def item_stat(id, field)
        return 0 if id.nil? || id == 0
        row = @state.party.db_item(id)
        return 0 unless row
        (row.respond_to?(field) ? row.send(field) : nil) || 0
      end

      # The summed equip-bonus points of item `id` across all four battle
      # stats -- #equip_delta's own total, kept for that method's use.
      def item_stat_sum(id)
        STAT_POINT_FIELDS.reduce(0) { |s, f| s + item_stat(id, f) }
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

      # The candidate's real net delta for one raw database `field` against
      # what is equipped now -- not just the two items landing in *this*
      # slot. Confirmed against EasyRPG's actual C++ source: `Scene_Equip::
      # UpdateStatusWindow` (`src/scene_equip.cpp`) also subtracts the
      # *other* hand's item when either it or the candidate is a 両手持ち
      # weapon (`Actor#two_handed?`), since equipping either one forces the
      # opposite slot empty -- the exact side effect `Actor#equip_item` /
      # `#free_two_handed_slot` already applies for real, which this preview
      # ignored (id 0, "Remove", never triggers it either way, matching
      # EasyRPG's own `current_item &&` guard -- removing an item never
      # forces anything off the other hand). #draw_stat_row calls this once
      # per battle stat; #equip_delta below is its sum across all four.
      def stat_field_delta(id, field)
        delta = item_stat(id, field) - item_stat(actor.equipment[@slot_index], field)
        other = other_hand_item
        if id != 0 && other && (actor.two_handed?(other) || actor.two_handed?(id))
          delta -= item_stat(other, field)
        end
        delta
      end

      # The candidate's combined net stat-point delta across all four battle
      # stats -- #stat_field_delta summed, not a display value in its own
      # right any more (see #draw_stat_row's per-stat preview, which replaced
      # the single summed comparison arrow this method used to drive).
      def equip_delta(id)
        STAT_POINT_FIELDS.reduce(0) { |s, f| s + stat_field_delta(id, f) }
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
        build_stats_window
        refresh_desc
      end
    end

  end
end
