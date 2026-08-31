class RPG2k
  module Scene
    # The field equip screen (main menu -> Equip). Shows one party member's five
    # equipment slots and current stats; LEFT/RIGHT cycle the member. Choosing a
    # slot lists the bag's items that fit it, in a two-column grid, with Remove
    # always appended after them (drawn as a blank cell -- see #candidates);
    # choosing one equips it -- swapping the previously-worn item back into the
    # bag -- or (choosing Remove) empties the slot. See #candidates. The
    # bag-aware equip logic is Game::Party#equip_candidates /
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

      # The candidate list is a two-column grid, not a single stacked column
      # -- confirmed against genuine RPG_RT under wine with a four-candidate
      # bag (ダガー/グラディウス/マンゴーシュ/アサシンダガー, none actor-
      # restricted), which filled row-major (candidate 0 top-left, candidate
      # 1 top-right, candidate 2 second row left, ...), the same COLUMN_MAX=2
      # shape already ported to Scene::ItemMenu/Scene::SkillMenu -- see
      # #candidates and #build_cand_window's own doc comments for the fuller
      # writeup (row-major layout, always-appended trailing Remove cell,
      # fixed window height) and #update_items for the cursor-navigation
      # citation.
      COLUMN_MAX = 2

      # `actor_index` is which party member the screen opens on -- the one
      # `Scene::Menu#enter_actor_selection` preselected from the menu's own
      # party list, matching a reference implementation's own equip-scene
      # constructor (which takes the same parameter), defaulting to 0 (the
      # leader) for callers that never had a picker to begin with, e.g. the
      # host test harnesses. LEFT/RIGHT still cycle from there once inside,
      # unlike Scene::SkillMenu, the same way that reference implementation's
      # own equip-selection update does (unlike its skill-scene
      # counterpart); ported from its source, NOT independently confirmed
      # against genuine RPG_RT under wine.
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
        # Every live window needs its own #update called every frame to
        # advance its selection-cursor blink (RPG2k::Window#update) -- this
        # scene never called it at all, the same gap Scene::Menu's own
        # #update had (see its own citation).
        @desc_window.update if @desc_window
        @stats_window.update if @stats_window
        @slot_window.update if @slot_window
        @cand_window.update if @cand_window
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

      # The slot cursor (DOWN/UP) auto-repeats while held -- `Input.repeat?`'s
      # own timing (`mruby-rgss/mrblib/lib.rb`) is independently measured
      # against the genuine RPG_RT.exe under wine, the same wiring every
      # other list here uses (see Scene::ItemMenu#update_items's fuller
      # writeup). The actor switch (RIGHT/LEFT) does **not**: ported from a
      # reference implementation's actual source, NOT independently
      # confirmed against genuine RPG_RT under wine -- its equip-selection
      # update checks the trigger only, never the repeat signal, since each
      # switch pushes a whole new scene instance rather than
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
        # cited to a reference implementation's own live source (gating
        # both branches on the party having more than one actor), the exact
        # kind of claim this session's
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
          # for such an actor, or for a slot currently holding a cursed item,
          # ported from a reference implementation's equip-selection update
          # (NOT independently confirmed against genuine RPG_RT under wine),
          # rather than opening it and rejecting whatever gets chosen there
          # -- a rejected Decision plays Buzzer, matching every other
          # "confirmed but refused" case this scene's siblings handle the
          # same way.
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

      # The slot's fitting bag items, with a trailing Remove entry (id 0)
      # always appended after them. (A 二刀流 actor's shield slot lists
      # weapons instead of shields, which is why `actor` goes along -- see
      # Game::Party#equip_candidates.)
      #
      # Cycle #128 found the Remove-inclusion bug (this codebase used to
      # *prepend* Remove unconditionally, making it a permanent extra choice
      # ahead of every real one) but concluded from a 0/1/2-real-candidate
      # comparison that real RPG_RT *drops* Remove entirely once any real
      # candidate exists -- because none of those captures ever pressed
      # DOWN past the last visibly-populated row. **Follow-up (cycle #129):
      # that conclusion was wrong.** Confirmed against a genuine RPG_RT.exe
      # under wine with a *four*-candidate bag (ダガー/グラディウス/
      # マンゴーシュ/アサシンダガー, filling a complete 2x2 grid -- see
      # COLUMN_MAX): pressing DOWN twice from the top-left cell (column-
      # locked, landing on row 2's own left cell each time) reached a fifth,
      # visually blank cell one row below the last full row -- still
      # genuinely selectable (a cursor box draws around it) and with its own
      # distinct stat-preview delta, confirmed *identical* (870 -> 150 on
      # the Atk row, both times) to the blank Remove row a separate 2-real-
      # candidate capture (ダガー/グラディウス only, same actor/equipped
      # weapon) reached the same way -- proving both are the same computed
      # entry (id 0, unequip), not a rendering artifact. Pressing LEFT from
      # that cell moved the cursor to the *last real* candidate (row 2's own
      # right cell, アサシンダガー) -- a genuine row-crossing flat-index
      # move, confirmed by its own distinct stat delta and description text
      # -- so Remove is a real, ordinary list entry at row-major position
      # `real.size`, not a separate mode. So the true rule is simply "the
      # real candidates, plus Remove always appended after them" -- id 0
      # never has special positioning, and is never omitted; #build_cand_
      # window draws it as a blank cell (see its own doc comment) which is
      # why a short list *looks* like it has no Remove option unless the
      # cursor is actually moved onto it.
      def candidates
        return @candidates if @candidates
        real = @state.party.equip_candidates(@slot_index, actor)
        @candidates = real + [[0, 0]]
      end

      # Cursor movement mirrors Scene::ItemMenu#move_item_cursor exactly --
      # DOWN/UP move by a whole row (COLUMN_MAX cells) and UP/DOWN off the
      # grid's own top/bottom is a no-op (confirmed: two DOWNs from the
      # trailing Remove cell described above left the cursor exactly there,
      # not wrapping); RIGHT/LEFT move by one cell, bounded only by the
      # list's own absolute ends, with no row-boundary check -- confirmed by
      # the LEFT-from-Remove row-crossing move documented on #candidates.
      def move_cand_cursor(delta)
        target = @cand_index + delta
        return if target < 0 || target >= candidates.size
        @cand_index = target
        refresh_cand_cursor
        play_system_se(SFX_CURSOR)
      end

      def update_items
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_items
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_cand_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_cand_cursor(-COLUMN_MAX)
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_cand_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_cand_cursor(-1)
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
      # highlighted candidate in :items mode (blank for the trailing Remove
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
      # order a reference implementation's own stat-drawing path draws them
      # (Atk/Def/Spirit/Agility -- ported from that implementation's
      # source, NOT independently confirmed against
      # genuine RPG_RT under wine); this codebase's own `term(:mind, ...)`/
      # `#int` name RPG2000's "Spirit" stat "Int" instead, matching
      # status_menu.rb.
      STAT_DEFS = [
        [:attack, 'Atk', :atk_points1, :atk, :effective_atk, :affect_attack],
        [:defense, 'Def', :def_points1, :def, :effective_def, :affect_defense],
        [:mind, 'Int', :spi_points1, :int, :effective_int, :affect_spirit],
        [:agility, 'Agi', :agi_points1, :agi, :effective_agi, :affect_agility]
      ].freeze

      # Four independent stat rows -- one "label value" per row while
      # browsing the slot list, or, while browsing candidates, "label value
      # > new_value" comparisons -- ported from a reference implementation's
      # actual stat-drawing path, NOT independently confirmed against
      # genuine RPG_RT under wine: it draws the actor name once,
      # then loops the four stats one row apart -- a
      # genuinely separate row per stat, each an old value, an arrow, and a
      # new value coloured by a comparison-driven palette (0 unchanged / 2
      # up / 3 down), never a single combined verdict for the whole item (see
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
          # ported from a reference implementation's own stat-drawing path,
          # NOT independently confirmed against genuine RPG_RT under wine:
          # it draws each stat via direct actor accessors that run the base
          # value through a state-adjustment step against
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
            # mirroring that same reference implementation's own
            # status-window update: it rebuilds each battle stat from the
            # raw base value (equipment excluded) plus each equipped item's
            # own point field, clamps, then applies the state adjustment --
            # the state adjustment
            # is the last step, not folded additively into the raw delta.
            delta = stat_field_delta(cand_id, field)
            # Clamped to 1..999 (`Game::Actor::MAX_EFFECTIVE_STAT`, matching
            # that reference implementation's own equivalent clamp) *before*
            # the state adjustment -- the reference's clamp
            # runs ahead of the state-adjustment step, not after.
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
            # That reference implementation's own new-value color logic compares
            # the two *displayed* (state-adjusted) values, not the raw item
            # delta's sign -- the two usually agree, but only this matches
            # the reference at a clamp boundary or under a halving state.
            color_idx = new_value == value ? 0 : (new_value > value ? 2 : 3)
            draw_system_text c, x, y, new_w, LINE_H, new_text, @skin, color_idx
          end
        end
      end

      # Y (screen-absolute) both the slot list and the candidate grid open
      # at -- confirmed against genuine RPG_RT under wine: the candidate
      # window (see #build_cand_window) starts at exactly this same row,
      # replacing the slot list in place while browsing candidates, not
      # anchored to the bottom of whatever content it happens to hold.
      def slot_window_y
        DESC_H + LINE_H * (1 + STAT_DEFS.size) + Window::BORDER * 2
      end

      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SCREEN_W - Window::BORDER * 2
        h = @slots.size * LINE_H
        y = slot_window_y
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
      # slot. Ported from a reference implementation's actual C++ source,
      # NOT independently confirmed against genuine RPG_RT under wine: its
      # status-window update also subtracts the
      # *other* hand's item when either it or the candidate is a 両手持ち
      # weapon (`Actor#two_handed?`), since equipping either one forces the
      # opposite slot empty -- the exact side effect `Actor#equip_item` /
      # `#free_two_handed_slot` already applies for real, which this preview
      # ignored (id 0, "Remove", never triggers it either way, matching
      # that reference implementation's own current-item guard -- removing
      # an item never forces anything off the other hand). #draw_stat_row calls this once
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

      # Column width for the candidate grid -- identical formula to
      # Scene::ItemMenu#item_col_w (see COLUMN_MAX's own doc comment).
      def cand_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      # The candidate window is a fixed-size grid, not sized to the
      # candidate count -- confirmed against genuine RPG_RT under wine: a
      # 2-real-candidate capture and a 4-real-candidate capture (same actor,
      # same slot) drew a window with *pixel-identical* top/bottom borders
      # both times (measured off the wine framebuffer), always starting at
      # #slot_window_y (replacing the slot list in place) and always
      # reaching exactly the bottom of the screen -- six grid rows' worth of
      # interior regardless of how many of those cells a real entry (or the
      # trailing Remove cell -- see #candidates) actually occupies; the rest
      # draw as empty background. This codebase used to size the window
      # tightly to `candidates.size` rows and anchor it to the *bottom* of
      # the screen, which only happened to look right when the list was
      # long enough to reach that same six-row mark. **Not independently
      # re-verified beyond 5 entries** (4 real + Remove, this cycle's own
      # test bag) whether real RPG_RT scrolls or otherwise handles a
      # candidate count that would overflow the six-row/twelve-cell grid --
      # left unaddressed, since #move_cand_cursor's own bound
      # (`candidates.size`) never lets the cursor reach a cell past the
      # real content either way, matching every capture actually taken.
      def build_cand_window
        @cand_window.dispose if @cand_window
        rows = candidates
        inner_w = SCREEN_W - Window::BORDER * 2
        y = slot_window_y
        h = SCREEN_H - y - Window::BORDER * 2
        @cand_window = Window.new(0, y, SCREEN_W, h + Window::BORDER * 2)
        @cand_window.z = 450
        @cand_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        col_w = cand_col_w
        rows.each_with_index do |(id, count), i|
          # Remove (id 0) draws nothing -- confirmed against genuine RPG_RT
          # under wine, which shows a blank cell there (still a real,
          # selectable, functional entry; see #candidates), not the literal
          # "(Remove)" label this codebase used to draw.
          next if id == 0
          x = (i % COLUMN_MAX) * col_w
          yy = (i / COLUMN_MAX) * LINE_H
          c.draw_text x, yy, col_w - 40, LINE_H, item_name(id)
          c.draw_text x + col_w - 40, yy, 40, LINE_H, ":#{count}"
        end
        @cand_window.contents = c
        refresh_cand_cursor
      end

      def refresh_cand_cursor
        return unless @cand_window
        col_w = cand_col_w
        x = (@cand_index % COLUMN_MAX) * col_w
        y = (@cand_index / COLUMN_MAX) * LINE_H
        @cand_window.cursor_rect = Rect.new(x, y, col_w, LINE_H)
        build_stats_window
        refresh_desc
      end
    end

  end
end
