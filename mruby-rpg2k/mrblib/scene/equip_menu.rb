class RPG2k
  module Scene
    # The field equip screen (main menu -> Equip). Four windows tile the whole
    # screen at once -- the description banner across the top, the actor's
    # stat panel bottom-left of it, the five equipment slots to its right and
    # the fitting-items grid filling everything below -- all four present in
    # both modes; see LAYOUT below for the pixel measurements. LEFT/RIGHT
    # cycle the member. Moving the slot cursor re-fills the candidate grid for
    # that slot (the grid is never hidden); Decision on a slot just moves focus
    # into the grid, and choosing an entry there equips it -- swapping the
    # previously-worn item back into the bag -- or (choosing the trailing blank
    # Remove entry) empties the slot. See #candidates. The bag-aware equip
    # logic is Game::Party#equip_candidates / equip_from_bag / unequip_to_bag
    # (host-tested); this is the RGSS UI over it, mirroring Scene::ItemMenu's
    # helpers. A two-handed weapon empties the other hand
    # (Actor#free_two_handed_slot) and a 二刀流 actor's shield slot lists
    # weapons instead of shields (#equip_candidates, given `actor`) -- both
    # handled by the party-level logic this scene just calls through to.
    class EquipMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # LAYOUT -- every window rect below is pixel-measured on a genuine
      # RPG_RT.exe under wine (Nepheshel, cycle #250; 640x480 captures halved
      # to the native 320x240, window edges read off the skin's white/purple/
      # black frame runs). The four windows tile the screen exactly, with no
      # overlap and no gaps, and *all four are live in both modes*:
      #
      #   description banner   (0,   0, 320,  32)
      #   stat panel           (0,  32, 124,  96)
      #   equipment slots      (124, 32, 196,  96)
      #   candidate grid       (0, 128, 320, 112)
      #
      # This class used to stack the stat panel and the slot list as two
      # full-width boxes and to *replace* the slot list with the candidate
      # grid on Decision; genuine RPG_RT puts the stat panel and the slot
      # list side by side on the same row and keeps the candidate grid on
      # screen the whole time, re-filling it as the slot cursor moves.
      DESC_H = LINE_H + Window::BORDER * 2                # 32
      PANEL_Y = DESC_H                                    # 32
      PANEL_H = LINE_H * 5 + Window::BORDER * 2           # 96
      STATS_W = 124
      SLOT_W = SCREEN_W - STATS_W                         # 196
      CAND_Y = PANEL_Y + PANEL_H                          # 128
      CAND_H = SCREEN_H - CAND_Y                          # 112

      # The candidate list is a two-column grid, not a single stacked column
      # -- confirmed against genuine RPG_RT under wine with a four-candidate
      # bag (ダガー/グラディウス/マンゴーシュ/アサシンダガー, none actor-
      # restricted), which filled row-major (candidate 0 top-left, candidate
      # 1 top-right, candidate 2 second row left, ...), and re-confirmed in
      # cycle #250 with a fourteen-weapon bag. It is the very same widget
      # Scene::ItemMenu draws, down to the pixel: two 144px cells at content
      # x 0 and 160 (a 16px gutter, NOT the edge-to-edge 304/2 == 152 split
      # this class used to draw), each row's held count written as `:` at
      # content x cell+120 plus a figure right-aligned in the 12px cell
      # ending at cell+144, and a six-row box that scrolls a row at a time
      # with the windowskin's blinking arrows on its top and bottom frame
      # edges. Cycle #250's fourteen-weapon capture is what pinned the
      # scrolling: the box showed twelve cells with a down arrow, one DOWN
      # past the last visible row scrolled by exactly one grid row (both
      # arrows then showing), and the last row held the trailing blank
      # Remove cell with only the up arrow left.
      COLUMN_MAX = 2

      # 16px gutter between the two 144px cells, and the `:`-plus-figure
      # count column flush against each cell's right edge -- measured as
      # above; identical to Scene::ItemMenu's own constants of the same name.
      COLUMN_GAP = 16
      COUNT_W = 24
      COUNT_SEP_W = 6
      COUNT_NUM_W = 12

      # Rows of the candidate grid that fit in its fixed-height box.
      VISIBLE_ROWS = (CAND_H - Window::BORDER * 2) / LINE_H   # 6

      # Content x the equipped item's name starts at in the slot list, beside
      # its slot label at content x 0 (measured: every slot's label glyphs
      # begin at content x 0 and every item name's at content x 60).
      SLOT_NAME_X = 60

      # Stat-row columns, in the stat panel's own content coordinates
      # (content width 124 - 8*2 == 108). Measured on genuine RPG_RT under
      # wine (cycle #250) from two saves whose figures differ in width -- a
      # level-50 leader (three-digit 370/407/368/380) and a level-1 copy
      # (two-digit 42/15/20/20):
      #
      #   x   0 ..  36   the stat's term, left-aligned  (swatch 1)
      #   x  ?? ..  78   the current value, RIGHT-aligned to x 78
      #                  ("370" ran 60..77, "42" ran 66..77)  (swatch 0)
      #   x  78 ..  90   a full-width `→`                (swatch 1)
      #   x  ?? .. 108   the previewed value, RIGHT-aligned to the content
      #                  edge ("204" ran 90..107, "69" ran 96..107)
      #
      # The arrow is drawn in BOTH modes: while the slot cursor is being
      # moved every row reads "term value →" with the arrow and nothing
      # after it; only the previewed figure appears and disappears.
      STAT_VALUE_R = 78
      STAT_ARROW_X = STAT_VALUE_R
      STAT_ARROW_W = 12
      STAT_ARROW = "→".freeze

      # Windowskin palette swatches this screen draws with, all sampled off
      # genuine RPG_RT frames (cycle #250) against Nepheshel's own System
      # graphic: the stat terms, the slot labels and the `→` all take swatch
      # 1's blue (132,170,255 down to 49,89,173) while the actor's name, the
      # current values, the equipped item names, the candidate names and
      # their counts and the description line all take swatch 0's white
      # (247,251,255 down to 107,182,255). This class used to draw every one
      # of them in flat white.
      LABEL_COLOR = 1
      TEXT_COLOR = 0

      # The previewed figure's swatch, by how it compares with the current
      # one -- measured (cycle #250): a *lower* figure sampled swatch 3
      # (99,166,247 / 82,150,239 / 57,134,231), a *higher* one swatch 2
      # (255,235,206 / 255,219,181 / 247,186,132) and an unchanged one plain
      # swatch 0, exactly the three this class already used.
      SAME_COLOR = 0
      UP_COLOR = 2
      DOWN_COLOR = 3

      # Scroll indicators for a candidate list longer than VISIBLE_ROWS: the
      # same blinking windowskin arrow cells Scene::ItemMenu draws, here on
      # the candidate box's own top and bottom frame edges. Measured on
      # genuine RPG_RT.exe under wine (cycle #250, a fourteen-weapon bag =
      # eight grid rows): the up arrow's white pixels sat at native x
      # 155..164, y 129..133 -- the 16x8 cell at (152, 128) == `(SCREEN_W -
      # ARROW_W) / 2, CAND_Y` -- and the down arrow's at x 155..164,
      # y 233..236, the cell at (152, 232) == `SCREEN_H - ARROW_H`. Both
      # show while the slot cursor is being moved too, not only while the
      # grid has focus: they track the scroll position alone.
      ARROW_W = Window::ARROW_W
      ARROW_H = Window::ARROW_H
      ARROW_SRC_X = Window::ARROW_SRC_X
      UP_ARROW_SRC_Y = 8
      DOWN_ARROW_SRC_Y = Window::ARROW_SRC_Y
      ARROW_BLINK_FRAMES = Window::ARROW_BLINK_FRAMES

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
        @cand_top = 0
        @arrow_anim = 0
        @mode = :slots          # :slots list, or :items candidate pick
        @warned_missing_item_ids = {}
        @slots = [
          term(:weapon), term(:shield), term(:armor),
          term(:helmet), term(:accessory)
        ]
        build_desc_window
        build_stats_window
        build_slot_window
        build_cand_window
        build_arrow_sprites
      end

      def dispose
        @desc_window.dispose if @desc_window
        @stats_window.dispose if @stats_window
        @slot_window.dispose if @slot_window
        @cand_window.dispose if @cand_window
        @up_arrow.dispose if @up_arrow
        @down_arrow.dispose if @down_arrow
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
        tick_arrows
        @mode == :items ? update_items : update_slots
      end

      private

      def actor
        @state.party.actors[@actor_index]
      end

      def item_name(id)
        return nil if id.nil? || id == 0
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
          move_slot_cursor(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_slot_cursor(-1)
        # A solo party leaves RIGHT/LEFT silent no-ops -- this was only ever
        # cited to a reference implementation's own live source (gating
        # both branches on the party having more than one actor), the exact
        # kind of claim this session's
        # methodology treats as worth re-checking on its own. Independently
        # re-verified since (cycle #121, and again in cycle #250) against a
        # genuine RPG_RT.exe under wine: with a solo-actor party on the real
        # Equip screen, a single RIGHT tap followed by a single LEFT tap
        # left the captured frame pixel-identical (0 differing pixels,
        # `compare -fuzz 5%`) to the frame taken before the RIGHT -- the
        # only pixel movement anywhere in the sequence was the windowskin's
        # own constant cursor-blink noise floor (a steady 3200 px, present
        # between every frame pair regardless of input), not a rebuilt
        # screen or a moved actor. Confirmed correct; no code change.
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
          # (NOT independently confirmed against genuine RPG_RT under wine --
          # Nepheshel's database carries no cursed equipment and no
          # equipment-fixed actor to try it on), rather than opening it and
          # rejecting whatever gets chosen there -- a rejected Decision plays
          # Buzzer, matching every other "confirmed but refused" case this
          # scene's siblings handle the same way.
          if actor.equipment_fixed? || actor.slot_cursed?(@slot_index)
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @mode = :items
            refresh_cand_cursor
          end
        end
      end

      # Moving the slot cursor re-fills the candidate grid underneath it --
      # confirmed against genuine RPG_RT under wine (cycle #250): with the
      # cursor on 武器 the grid listed the bag's weapons, and a single DOWN
      # onto 盾 replaced it, in place, with the bag's only shield, before
      # any Decision was pressed. The grid's own cursor stays hidden until
      # Decision moves focus into it (a genuine frame showed exactly one
      # cursor, on the slot row, in this mode and two once the grid had
      # focus), and the scroll position restarts at the top for the new
      # slot's own list.
      def move_slot_cursor(delta)
        @slot_index = (@slot_index + delta) % @slots.size
        @candidates = nil
        @cand_index = 0
        @cand_top = 0
        refresh_slot_cursor
        build_cand_window
        play_system_se(SFX_CURSOR)
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
      # DOWN past the last visibly-populated row. That conclusion was wrong,
      # as cycle #129 established and cycle #250 re-confirmed outright: on a
      # genuine RPG_RT frame with an *empty* armour list the grid held a
      # single blank, cursored, previewing cell (id 0), and on one with
      # fourteen weapons the eighth grid row held that same blank cell
      # immediately after the fourteenth name -- i.e. Remove sits at
      # row-major position `real.size`, always, and is never omitted.
      # #build_cand_window draws it as a blank cell (see its own doc
      # comment) which is why a short list *looks* like it has no Remove
      # option unless the cursor is actually moved onto it.
      #
      # The order is the bag's own stored order, NOT ascending item id --
      # confirmed against genuine RPG_RT under wine (cycle #250) with a save
      # whose chunk-109 `item_ids` were written deliberately out of order
      # ([30, 27, 29, 28, 26, 66, 177], each with a distinct count so a row
      # identifies its id): the weapon slot's grid listed them 30/27/29/28/66
      # in exactly that order, and a fourteen-weapon rerun
      # ([44, 27, 45, 28, 46, 29, 47, 30, 48, 31, 49, 32, 50, 33]) listed all
      # fourteen in stored order too. Item 26 -- a dagger whose database
      # `actor_set` excludes this actor -- was absent from both, so an
      # actor-restricted item is dropped from the list outright rather than
      # drawn in the disabled swatch the way Scene::ItemMenu greys an
      # unusable bag row.
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
      # the LEFT-from-Remove move documented on #candidates.
      def move_cand_cursor(delta)
        target = @cand_index + delta
        return if target < 0 || target >= candidates.size
        @cand_index = target
        if scroll_cand_list_to_cursor
          build_cand_window
        else
          refresh_cand_cursor
        end
        play_system_se(SFX_CURSOR)
      end

      # Keep the cursor's grid row inside the VISIBLE_ROWS-tall box, moving
      # `@cand_top` by the smallest amount that does so; true when it moved
      # (the box then needs redrawing for the new top row). Measured on
      # genuine RPG_RT under wine -- see COLUMN_MAX's own note for the
      # fourteen-weapon capture that pinned the one-row-at-a-time scroll.
      def scroll_cand_list_to_cursor
        row = @cand_index / COLUMN_MAX
        top = @cand_top
        top = row if row < top
        top = row - VISIBLE_ROWS + 1 if row >= top + VISIBLE_ROWS
        return false if top == @cand_top
        @cand_top = top
        true
      end

      def cand_row_count
        [(candidates.size + COLUMN_MAX - 1) / COLUMN_MAX, 1].max
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

      # Confirming an entry equips it and hands focus straight back to the
      # slot list, with every window redrawn for the new loadout --
      # confirmed against genuine RPG_RT under wine (cycle #250): choosing a
      # 両手持ち weapon left the slot list reading the new weapon on its
      # first row and a *blank* second row (the shield it forced off), the
      # stat panel showing the new totals with a bare trailing `→`, and the
      # candidate grid re-listing the bag with both displaced items now in
      # it -- and only one cursor on screen again, on the slot row.
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
        @cand_index = 0
        @cand_top = 0
        @mode = :slots
        build_cand_window
        build_stats_window
        refresh_desc
      end

      def rebuild_for_actor
        @slot_index = @slots.size - 1 if @slot_index >= @slots.size
        @candidates = nil
        build_stats_window
        build_slot_window
        build_cand_window
      end

      # The highlighted item's flavour text, in a one-line banner across the
      # very top of the screen -- confirmed against genuine RPG_RT under
      # wine, which shows the database item's own `description` field there
      # (e.g. a weapon's "[斬光風龍神]イリスの想いを宿す時の剣"); this scene
      # drew no such banner at all. Tracks whichever item is currently under
      # the cursor: the slot's own equipped item in :slots mode, or the
      # highlighted candidate in :items mode -- blank for the trailing
      # Remove entry and for an empty slot, both re-confirmed on genuine
      # frames in cycle #250.
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
        draw_system_text @desc_contents, 0, 0, @desc_contents.width, LINE_H,
                         text, @skin, TEXT_COLOR
      end

      # The stat panel: the actor's name on its own first row, then the four
      # battle stats one row apart -- see LAYOUT for the window rect and the
      # STAT_* constants for the columns inside it.
      def build_stats_window
        @stats_window.dispose if @stats_window
        inner_w = STATS_W - Window::BORDER * 2
        h = LINE_H * (1 + STAT_DEFS.size)
        @stats_window = Window.new(0, PANEL_Y, STATS_W, PANEL_H)
        @stats_window.z = 400
        @stats_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = actor
        draw_system_text c, 0, 0, inner_w, LINE_H, a.name.to_s, @skin, TEXT_COLOR
        draw_stat_row(c, a)
        @stats_window.contents = c
      end

      # RPG2000 term / equip-bonus field / actor-accessor / effective-stat
      # method / state-flag quintuples for the four battle stats, in the
      # order genuine RPG_RT draws them -- 攻撃力 / 防御力 / 精神力 / 敏捷性,
      # read straight off a wine capture of the real screen (cycle #250),
      # one row each, in that order, below the actor's name and nothing
      # else (no max HP/SP rows, no equipment summary). This codebase's own
      # `term(:mind)`/`#int` name RPG2000's "Spirit" stat "Int" instead,
      # matching status_menu.rb.
      STAT_DEFS = [
        [:attack, :atk_points1, :atk, :effective_atk, :affect_attack],
        [:defense, :def_points1, :def, :effective_def, :affect_defense],
        [:mind, :spi_points1, :int, :effective_int, :affect_spirit],
        [:agility, :agi_points1, :agi, :effective_agi, :affect_agility]
      ].freeze

      # Four independent stat rows -- "term value →" while browsing the slot
      # list, "term value → new" while browsing candidates. The trailing
      # arrow is there in *both* modes (measured, see STAT_VALUE_R); only
      # the previewed figure comes and goes, and it is coloured by comparing
      # the two displayed figures (see UP_COLOR/DOWN_COLOR). Never a single
      # combined verdict for the whole item (see #build_cand_window's own
      # history for the summed-arrow this replaced) and never sharing a row
      # with any other stat.
      def draw_stat_row(c, a)
        previewing = @mode == :items
        cand_id = previewing ? candidates[@cand_index].first : nil
        STAT_DEFS.each_with_index do |(term_key, field, accessor,
                                        effective_method, stat_flag), i|
          y = LINE_H * (1 + i)
          # State-adjusted (halve/double), not the raw base+equip total --
          # ported from a reference implementation's own stat-drawing path,
          # NOT independently confirmed against genuine RPG_RT under wine
          # (cycle #250's captures were all of a stateless actor, where the
          # two readings coincide): it draws each stat via direct actor
          # accessors that run the base value through a state-adjustment
          # step against whatever states the actor currently carries.
          # `Game::Party#effective_atk`/`#effective_def`/`#effective_int`/
          # `#effective_agi` already port this (built for skill formulas);
          # this screen never called them.
          value = @state.party.send(effective_method, a)
          draw_system_text c, 0, y, STATS_W, LINE_H, term(term_key), @skin, LABEL_COLOR
          draw_system_text c, 0, y, STAT_VALUE_R, LINE_H, value.to_s, @skin, TEXT_COLOR, 2
          draw_system_text c, STAT_ARROW_X, y, STAT_ARROW_W, LINE_H, STAT_ARROW,
                           @skin, LABEL_COLOR
          next unless previewing
          # The preview recomputes the new *base* total (this stat's own
          # raw base+equip accessor plus the candidate's raw point delta,
          # matching `#effective_atk` et al.'s own base+equip reading)
          # and only then reapplies the state halve/double, exactly
          # mirroring that same reference implementation's own
          # status-window update: it rebuilds each battle stat from the
          # raw base value (equipment excluded) plus each equipped item's
          # own point field, clamps, then applies the state adjustment --
          # the state adjustment is the last step, not folded additively
          # into the raw delta. The plain base+equip half of that is
          # measured: on a genuine frame the leader's 攻撃力 370 previewed
          # as 204 for a 54-point dagger and 150 for Remove, i.e. exactly
          # "unequipped base 150, plus the candidate's own points".
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
          # That reference implementation's own new-value color logic compares
          # the two *displayed* (state-adjusted) values, not the raw item
          # delta's sign -- the two usually agree, but only this matches
          # the reference at a clamp boundary or under a halving state.
          color_idx = if new_value == value
                        SAME_COLOR
                      else
                        new_value > value ? UP_COLOR : DOWN_COLOR
                      end
          draw_system_text c, 0, y, c.width, LINE_H, new_value.to_s, @skin, color_idx, 2
        end
      end

      # The five equipment slots, to the right of the stat panel and on the
      # same row as it -- see LAYOUT. An empty slot draws its label and
      # nothing else: confirmed on genuine RPG_RT under wine (cycle #250), a
      # leader wearing only a weapon showed 盾/鎧/守護石/装飾品 with blank
      # name columns, not the "-" placeholder this class used to draw.
      def build_slot_window
        @slot_window.dispose if @slot_window
        inner_w = SLOT_W - Window::BORDER * 2
        h = @slots.size * LINE_H
        @slot_window = Window.new(STATS_W, PANEL_Y, SLOT_W, PANEL_H)
        @slot_window.z = 400
        @slot_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        eq = actor.equipment
        @slots.each_with_index do |label, i|
          y = i * LINE_H
          draw_system_text c, 0, y, SLOT_NAME_X, LINE_H, label, @skin, LABEL_COLOR
          name = item_name(eq[i])
          next if name.nil?
          draw_system_text c, SLOT_NAME_X, y, inner_w - SLOT_NAME_X, LINE_H,
                           name, @skin, TEXT_COLOR
        end
        @slot_window.contents = c
        refresh_slot_cursor
      end

      # The slot cursor spans the whole row, the full content width --
      # measured on a genuine frame (cycle #250): with the 盾 row selected
      # the green cursor frame ran native x 128..315, y 56..71, i.e. the
      # 180x16 content cell at (0, 16) plus Game::WindowCursor's own 4px
      # horizontal overhang.
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
      # slot. The 両手持ち half of it is measured on genuine RPG_RT under
      # wine (cycle #250): highlighting a two-handed sword on a leader
      # wearing a 25-defence weapon and a 70-defence shield previewed
      # 防御力 407 → 312, i.e. both the weapon's and the *shield's* points
      # gone, while the one-handed candidates on the same list previewed
      # 407 → 382 (the weapon's alone). Removing an item never forces
      # anything off the other hand either way (id 0 is guarded out below,
      # matching that same capture's 407 → 382 for Remove). #draw_stat_row
      # calls this once per battle stat; #equip_delta below is its sum
      # across all four.
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

      # Cell width for the candidate grid: 144px, two of them COLUMN_GAP
      # apart -- identical formula (and identical measured numbers) to
      # Scene::ItemMenu#item_col_w. See COLUMN_MAX's own doc comment.
      def cand_col_w
        (SCREEN_W - Window::BORDER * 2 - COLUMN_GAP * (COLUMN_MAX - 1)) / COLUMN_MAX
      end

      # Content x of column `col`'s cell -- 0 and 160 (measured).
      def cand_col_x(col)
        col * (cand_col_w + COLUMN_GAP)
      end

      # The candidate window is a fixed-size box filling everything below the
      # stat/slot row, not sized to the candidate count -- confirmed against
      # genuine RPG_RT under wine: captures with 0, 1, 5 and 15 entries all
      # drew a box with pixel-identical frame edges (native y 128..239), six
      # grid rows' worth of interior regardless of how many of those cells a
      # real entry (or the trailing Remove cell -- see #candidates) actually
      # occupies; the rest draw as empty background. This codebase used to
      # size the window tightly to `candidates.size` rows and anchor it to
      # the *bottom* of the screen. A list longer than the six rows scrolls
      # a row at a time (see #scroll_cand_list_to_cursor and the ARROW_*
      # constants), measured with a fourteen-weapon bag in cycle #250 --
      # previously left open here.
      def build_cand_window
        @cand_window.dispose if @cand_window
        rows = candidates
        inner_w = SCREEN_W - Window::BORDER * 2
        h = VISIBLE_ROWS * LINE_H
        @cand_window = Window.new(0, CAND_Y, SCREEN_W, CAND_H)
        @cand_window.z = 450
        @cand_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        col_w = cand_col_w
        first = @cand_top * COLUMN_MAX
        last = first + VISIBLE_ROWS * COLUMN_MAX - 1
        rows.each_with_index do |(id, count), i|
          next if i < first || i > last
          # Remove (id 0) draws nothing -- confirmed against genuine RPG_RT
          # under wine, which shows a blank cell there (still a real,
          # selectable, functional entry; see #candidates), not the literal
          # "(Remove)" label this codebase used to draw.
          next if id == 0
          x = cand_col_x(i % COLUMN_MAX)
          y = (i / COLUMN_MAX - @cand_top) * LINE_H
          draw_system_text c, x, y, col_w - COUNT_W, LINE_H, item_name(id),
                           @skin, TEXT_COLOR
          draw_system_text c, x + col_w - COUNT_W, y, COUNT_SEP_W, LINE_H, ':',
                           @skin, TEXT_COLOR
          draw_system_text c, x + col_w - COUNT_NUM_W, y, COUNT_NUM_W, LINE_H,
                           count.to_s, @skin, TEXT_COLOR, 2
        end
        @cand_window.contents = c
        refresh_cand_cursor
        refresh_arrows
      end

      # The grid's cursor is one 144px cell, and it is hidden entirely while
      # the slot list has focus -- measured (cycle #250): in :items mode the
      # green frame ran native x 4..155, y 136..151 (the content cell at
      # (0, 0) plus Game::WindowCursor's 4px horizontal overhang) alongside
      # the slot list's own, and in :slots mode the candidate box carried no
      # cursor pixels at all.
      def refresh_cand_cursor
        return unless @cand_window
        if @mode == :items
          x = cand_col_x(@cand_index % COLUMN_MAX)
          y = (@cand_index / COLUMN_MAX - @cand_top) * LINE_H
          @cand_window.cursor_rect = Rect.new(x, y, cand_col_w, LINE_H)
        else
          @cand_window.cursor_rect = Rect.new(0, 0, 0, 0)
        end
        build_stats_window
        refresh_desc
      end

      # Advance the scroll arrows' blink phase and refresh their visibility
      # -- mirrors Scene::ItemMenu#tick_arrows.
      def tick_arrows
        return unless @up_arrow
        @arrow_anim = (@arrow_anim + 1) % (ARROW_BLINK_FRAMES * 2)
        refresh_arrows
      end

      # An arrow shows while blinking "on" and while a grid row is hidden in
      # that direction, in either mode (see the ARROW_* constants).
      def refresh_arrows
        return unless @up_arrow
        blink_on = @arrow_anim < ARROW_BLINK_FRAMES
        @up_arrow.visible = blink_on && @cand_top > 0
        @down_arrow.visible = blink_on && @cand_top < cand_row_count - VISIBLE_ROWS
      end

      # The two arrow sprites, pinned to the candidate box's top and bottom
      # frame edges and centred horizontally -- see the ARROW_* constants.
      def build_arrow_sprites
        @up_arrow = build_arrow_sprite(UP_ARROW_SRC_Y)
        @up_arrow.y = CAND_Y
        @down_arrow = build_arrow_sprite(DOWN_ARROW_SRC_Y)
        @down_arrow.y = SCREEN_H - ARROW_H
        refresh_arrows
      end

      def build_arrow_sprite(src_y)
        sprite = Sprite.new
        sprite.z = 460
        sprite.x = (SCREEN_W - ARROW_W) / 2
        bmp = Bitmap.new(ARROW_W, ARROW_H)
        if @skin
          bmp.blt 0, 0, @skin, Rect.new(ARROW_SRC_X, src_y, ARROW_W, ARROW_H)
        else
          draw_arrow_fallback(bmp, src_y == UP_ARROW_SRC_Y)
        end
        sprite.bitmap = bmp
        sprite.visible = false
        sprite
      end

      def draw_arrow_fallback(bmp, pointing_up)
        color = Color.new(232, 232, 248, 255)
        ARROW_H.times do |row|
          r = pointing_up ? ARROW_H - 1 - row : row
          w = ARROW_W - r * 2
          next if w <= 0
          bmp.fill_rect r, row, w, 1, color
        end
      end
    end

  end
end
