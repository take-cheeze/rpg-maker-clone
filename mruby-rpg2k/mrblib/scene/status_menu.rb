class RPG2k
  module Scene
    # The field status screen (main menu -> Status, RPG2003 `menu_commands`
    # id 5). Shows one party member's full detail across **five windows**, and
    # LEFT/RIGHT cycle the member. Read-only, so there is no sub-mode.
    #
    # **Measured against a genuine RPG2003 `RPG_RT.EXE` under wine (cycle #256,
    # 2026-09-06): kk1.12 + the official RTP, its own `RPG_RT.EXE` on its own
    # data**, reached by playing the opening to the first menu and saving
    # (`Save01.lsd`), then resuming that save. Captures at 640x480 = the 320x240
    # logical screen doubled; every number below is halved from a pixel
    # measurement of those frames, never "by eye". Window rects come from each
    # frame's own border bbox (the visible frame runs 1px inside the window
    # rect, calibrated on the field menu's own command window, whose 88px width
    # is independently known):
    #
    #   actor panel   (0,   0, 124, 208)   face + name/class/title/condition/level
    #   gold          (0, 208, 124,  32)   the party's money, right-aligned
    #   HP/MP/EXP     (124,  0, 196,  64)  three "label cur / max" rows
    #   parameters    (124, 64, 196,  80)  attack/defense/mind/agility
    #   equipment     (124,144, 196,  96)  five slots
    #
    # They tile the screen exactly: 124+196 = 320 across, 208+32 = 240 down the
    # left, 64+80+96 = 240 down the right.
    class StatusMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # RPG2000 FaceSet geometry: a 4x4 grid of 48x48 cells (the same sheet
      # Scene::Menu's own party panel reads). The portrait sits flush in the
      # actor panel's own top-left content corner -- measured at screen
      # (8,8)..(56,56), i.e. content (0,0).
      FACE_SIZE = 48

      ACTOR_WINDOW_W = 124
      ACTOR_WINDOW_H = 208
      GOLD_WINDOW_H = SCREEN_H - ACTOR_WINDOW_H
      RIGHT_X = ACTOR_WINDOW_W
      RIGHT_W = SCREEN_W - ACTOR_WINDOW_W
      GAUGE_WINDOW_H = 64
      PARAM_WINDOW_H = 80
      EQUIP_WINDOW_H = SCREEN_H - GAUGE_WINDOW_H - PARAM_WINDOW_H

      # Actor panel rows, in content lines of 16px (glyph tops measured at
      # 12 + 16*line, the same +4 ascent offset every window in this port
      # already draws with). The portrait covers lines 0-2; the front/back
      # row label shares line 0 with it, right-aligned to the content width.
      # Each of the first four rows is a *pair* of lines -- the label on its
      # own line, the value on the next, indented to VALUE_X -- and the level
      # is the one row whose label and value share a line.
      ROW_LABEL_LINE = 0
      FIRST_PAIR_LINE = 3
      LEVEL_LINE = 11
      VALUE_X = 36
      # The level figure is right-aligned, its right edge measured at content
      # x=78 for both a one-digit ("1") and a two-digit ("27") level.
      LEVEL_VALUE_RIGHT = 78

      # The HP/MP/EXP window's three rows and the parameter window's four all
      # share one column grid: label at content x=0, the *current* figure
      # right-aligned with its right edge at 90, the slash drawn from 90, and
      # the maximum right-aligned with its right edge at 138. Measured across
      # 1-, 2-, 3-, 4- and 5-digit figures (13/2100, 96/96, 12345/79050).
      VALUE_CUR_RIGHT = 90
      VALUE_SLASH_X = 90
      VALUE_MAX_RIGHT = 138
      # The equipment window puts the item name at content x=60.
      EQUIP_VALUE_X = 60

      # At the maximum level both EXP fields read six dashes instead of a
      # number. Not measured on *this* screen (kk1.12's party is nowhere near
      # level 99 and the save-editing recipe used here only moves one actor to
      # a mid-level), but measured on the field menu's own EXP row of the same
      # runtime in cycle #248 -- same data, same six-cell fields, so the same
      # string is used rather than inventing a second convention. See
      # `Scene::Menu::STATUS_MAX_LEVEL_EXP`.
      MAX_LEVEL_EXP = '------'.freeze

      # RPG_RT draws these four actor-panel labels itself -- they have no slot
      # in the Term chunk at all (schema.rb's Terms run out at 153 with no
      # name/class/title/condition entry, and kk1.12's own table has none), so
      # the Japanese runtime's own wording is what a genuine frame shows:
      # 名前 / 職業 / 肩書き / 状態, all four measured on kk1.12's status screen.
      # Same for the front/back row indicator (前衛 / 後衛), which changes with
      # `Game::Actor#battle_row` -- confirmed by toggling a member's row from
      # the field menu's own Row command and re-opening this screen.
      NAME_LABEL = '名前'.freeze
      CLASS_LABEL = '職業'.freeze
      TITLE_LABEL = '肩書き'.freeze
      CONDITION_LABEL = '状態'.freeze
      ROW_FRONT_LABEL = '前衛'.freeze
      ROW_BACK_LABEL = '後衛'.freeze

      # Every label on this screen draws in the windowskin's system-palette
      # index 1 and every value in index 0, confirmed by sampling kk1.12's own
      # System graphic (`00-03file12.png`): its index-1 swatch is (113,239,186)
      # and the captured labels are (115,239,189) after the 16-bit reference X
      # server's RGB565 quantisation; index 0 is (250,250,255) against captured
      # values of (255,251,255). The one exception is a *current* HP/MP figure,
      # which recolours through #value_font_color: an edited save's 13/2100 HP
      # and 5/138 MP both drew in the index-4 swatch ((252,176,62) vs a
      # captured (255,178,57)), so the "at or below a quarter of max" critical
      # rule -- and its applying to MP as well as HP -- holds on genuine
      # RPG_RT. The condition's own name takes the state's database colour
      # (a violet (206,186,255) for the state the same save inflicted).
      LABEL_COLOR = 1

      # `actor_index` is which party member the screen opens on -- the one
      # `Scene::Menu#enter_actor_selection` preselected from the menu's own
      # party list -- defaulting to 0 (the leader) for callers that never had a
      # picker to begin with, e.g. the host test harnesses. LEFT/RIGHT cycle
      # from there once inside, confirmed under wine: RIGHT walked
      # ユーティル -> とんま and LEFT wrapped back past the leader to
      # エマワトソン, each redrawing the whole screen for the new actor.
      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = actor_index
        @warned_missing_item_ids = {}
        build_windows
      end

      def dispose
        windows.each { |w| w.dispose }
      end

      def update
        # Every live window needs its own #update called every frame to
        # advance its own animation/blink state (RPG2k::Window#update) --
        # this scene never called it at all, the same gap Scene::Menu's own
        # #update had (see its own citation). None of these five sets a
        # `cursor_rect`, so there is no selection highlight to blink here,
        # but the call is still correct to make for consistency and any
        # future animated window state.
        windows.each { |w| w.update }
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        # A solo party leaves RIGHT/LEFT silent no-ops -- ported from a
        # reference implementation's source, NOT independently confirmed
        # against genuine RPG_RT under wine (kk1.12's party is three members
        # from its first menu on, and this port must not touch a real save's
        # party list to shrink it -- see docs/TODO.md): its update loop gates
        # both branches on the party having more than one actor, not just the
        # trigger itself, so a lone hero's Status screen plays no cursor SE
        # and rebuilds nothing on either key.
        elsif party.size > 1 && Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          refresh
          play_system_se(SFX_CURSOR)
        elsif party.size > 1 && Input.trigger?(Input::LEFT)
          @actor_index -= 1
          @actor_index %= party.size
          refresh
          play_system_se(SFX_CURSOR)
        end
      end

      private

      def windows
        [@actor_window, @gold_window, @gauge_window, @param_window,
         @equip_window].compact
      end

      def item_name(id)
        return '' if id.nil? || id == 0
        it = @state.party.db_item(id)
        if it.nil?
          warn_missing_item(id)
          return "Item #{id}"
        end
        # A blank database name draws blank -- see Scene::ItemMenu's own
        # citation (cycle #254, measured under wine). An *empty* slot draws
        # blank too: kk1.12's leader has nothing in the accessory slot and
        # that row shows its label alone, with no placeholder of any kind.
        it.name.to_s
      end

      # #item_name's diagnostic for an equipped slot whose item id has no
      # database row -- the "item" case from docs/TODO.md's runtime error
      # catalog's dangling-id list (a database shrink leaving a stale
      # reference behind), on this screen's equipped-slot *display* path
      # rather than the field/battle Item-menu's inventory-*list*-filtering
      # one (a separate fix). The placeholder label is unchanged; this is
      # diagnostics only. Deduped per id for the scene's lifetime --
      # #item_name reruns every time the screen redraws (every LEFT/RIGHT
      # actor switch), and logging each of those for an id that never
      # resolves would spam the console for as long as the screen stays
      # open.
      def warn_missing_item(id)
        return if @warned_missing_item_ids[id]
        @warned_missing_item_ids[id] = true
        $stderr.puts "[RPG2k] Status screen: item ##{id} not found in the " \
                     "database, showing a placeholder label"
      end

      def build_windows
        @actor_window = new_window(0, 0, ACTOR_WINDOW_W, ACTOR_WINDOW_H)
        @gold_window = new_window(0, ACTOR_WINDOW_H, ACTOR_WINDOW_W, GOLD_WINDOW_H)
        @gauge_window = new_window(RIGHT_X, 0, RIGHT_W, GAUGE_WINDOW_H)
        @param_window = new_window(RIGHT_X, GAUGE_WINDOW_H, RIGHT_W, PARAM_WINDOW_H)
        @equip_window = new_window(RIGHT_X, GAUGE_WINDOW_H + PARAM_WINDOW_H,
                                   RIGHT_W, EQUIP_WINDOW_H)
        refresh
      end

      def new_window(x, y, w, h)
        win = Window.new(x, y, w, h)
        win.z = 400
        win.windowskin = @skin
        win
      end

      def new_contents(win)
        c = Bitmap.new(win.width - Window::BORDER * 2, win.height - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        c
      end

      # Redraw all five windows for the currently selected actor.
      def refresh
        a = @state.party.actors[@actor_index]
        draw_actor_panel a
        draw_gold
        draw_gauges a
        draw_params a
        draw_equipment a
      end

      def draw_actor_panel(a)
        c = new_contents(@actor_window)
        draw_battle_row c, a if rpg2003_party?
        draw_actor_face c, a
        pairs = [
          [NAME_LABEL, a.name.to_s],
          [CLASS_LABEL, a.respond_to?(:class_name) ? a.class_name.to_s : ''],
          [TITLE_LABEL, a.title.to_s]
        ]
        pairs.each_with_index do |(label, value), i|
          y = (FIRST_PAIR_LINE + i * 2) * LINE_H
          draw_system_text c, 0, y, c.width, LINE_H, label, @skin, LABEL_COLOR
          draw_system_text c, VALUE_X, y + LINE_H, c.width - VALUE_X, LINE_H,
                           value, @skin
        end
        # The condition keeps the same label-line/value-line shape, but its
        # value draws in the state's own palette colour (see LABEL_COLOR's
        # citation), and reads the database's "normal" term when there is no
        # state -- kk1.12 leaves that term empty, and the genuine frame drew
        # the line blank rather than substituting anything.
        y = (FIRST_PAIR_LINE + pairs.size * 2) * LINE_H
        draw_system_text c, 0, y, c.width, LINE_H, CONDITION_LABEL, @skin, LABEL_COLOR
        draw_actor_state c, a, VALUE_X, y + LINE_H, c.width - VALUE_X, LINE_H, @skin
        y = LEVEL_LINE * LINE_H
        draw_system_text c, 0, y, c.width, LINE_H, term(:level), @skin, LABEL_COLOR
        draw_system_text c, 0, y, LEVEL_VALUE_RIGHT, LINE_H, a.level.to_s, @skin, 0, 2
        @actor_window.contents = c
      end

      # The party's own Gold, right-aligned on the gold window's single line
      # -- the same amount-then-term run the field menu's own gold window
      # draws, in a window 124 wide instead of 88 (both measured; only the
      # width differs).
      def draw_gold
        c = new_contents(@gold_window)
        draw_system_text c, 0, 0, c.width, LINE_H,
                         "#{@state.party.gold}#{term(:gold)}", @skin, 0, 2
        @gold_window.contents = c
      end

      # HP / MP / EXP, one per line. The HP and MP labels are the *full*
      # terms (`hp`/`mp`, kk1.12's ＨＰ/ＭＰ), not the `hp_short`/`mp_short`
      # abbreviations the menu's own party panel uses; EXP has no full term
      # of its own and draws `exp_short` (kk1.12's "Ex"). The right-hand EXP
      # figure is the *absolute* next-level threshold (`#next_level_exp`),
      # not the remaining delta: a level-27 actor with 12345 EXP showed
      # 12345/79050, and 79050 - 12345 is not a curve value.
      def draw_gauges(a)
        c = new_contents(@gauge_window)
        draw_value_row c, 0, term(:hp), a.hp, a.display_max_hp, true
        draw_value_row c, 1, term(:mp), a.mp, a.display_max_mp, false
        nxt = a.next_level_exp
        if nxt.nil?
          draw_value_row c, 2, term(:exp_short), MAX_LEVEL_EXP, MAX_LEVEL_EXP
        else
          draw_value_row c, 2, term(:exp_short), a.exp, nxt
        end
        @gauge_window.contents = c
      end

      # One "label  cur / max" line in this screen's shared column grid.
      def draw_value_row(c, line, label, cur, max, can_knockout = nil)
        y = line * LINE_H
        draw_system_text c, 0, y, c.width, LINE_H, label, @skin, LABEL_COLOR
        color = can_knockout.nil? ? 0 : value_font_color(cur, max, can_knockout)
        draw_system_text c, 0, y, VALUE_CUR_RIGHT, LINE_H, cur.to_s, @skin, color, 2
        draw_system_text c, VALUE_SLASH_X, y, c.width - VALUE_SLASH_X, LINE_H, '/', @skin
        draw_system_text c, 0, y, VALUE_MAX_RIGHT, LINE_H, max.to_s, @skin, 0, 2
      end

      # Attack / Defense / Mind / Agility, in that order -- confirmed against
      # kk1.12's own database: its 精霊術師 (actor 3) has base 10/18/50/7 at
      # level 1 and the screen showed 20/21/54/7, each the base plus that
      # actor's own equipment bonus, so the third row is Mind and the fourth
      # Agility. The figures are the state-adjusted effective values
      # (`Game::Party#effective_*`), which is also what the equipment bonuses
      # above prove is being displayed rather than the raw curve value.
      def draw_params(a)
        c = new_contents(@param_window)
        rows = [
          [term(:attack), @state.party.effective_atk(a)],
          [term(:defense), @state.party.effective_def(a)],
          [term(:mind), @state.party.effective_int(a)],
          [term(:agility), @state.party.effective_agi(a)]
        ]
        rows.each_with_index do |(label, value), i|
          y = i * LINE_H
          draw_system_text c, 0, y, c.width, LINE_H, label, @skin, LABEL_COLOR
          draw_system_text c, 0, y, VALUE_CUR_RIGHT, LINE_H, value.to_s, @skin, 0, 2
        end
        @param_window.contents = c
      end

      # The five equipment slots, label then item name. The *second* slot's
      # label follows the actor's own 二刀流 flag: kk1.12's とんま
      # (`double_hand` set in the database) showed the weapon term 武器 twice
      # over its two equipped swords, where the single-weapon leader showed
      # the shield term on that row -- which for kk1.12 is the empty string,
      # and drew as a blank label rather than anything substituted.
      def draw_equipment(a)
        c = new_contents(@equip_window)
        eqp = a.equipment
        slot_labels(a).each_with_index do |label, i|
          y = i * LINE_H
          draw_system_text c, 0, y, c.width, LINE_H, label, @skin, LABEL_COLOR
          draw_system_text c, EQUIP_VALUE_X, y, c.width - EQUIP_VALUE_X, LINE_H,
                           item_name(eqp[i]), @skin
        end
        @equip_window.contents = c
      end

      def slot_labels(a)
        second = if a.respond_to?(:double_hand?) && a.double_hand?
                   term(:weapon)
                 else
                   term(:shield)
                 end
        [term(:weapon), second, term(:armor), term(:helmet), term(:accessory)]
      end

      # Whether this database is RPG2003 -- the RPG2003-only front/back row
      # indicator is gated on it, the same way the rest of this codebase gates
      # RPG2003-only presentation.
      def rpg2003_party?
        @state.party.respond_to?(:rpg2003?) && @state.party.rpg2003?
      end

      # The battle-row indicator: line 0 of the actor panel, right-aligned to
      # the content width (measured at screen x=92..113 for a 12px-per-glyph
      # pair whose cell ends exactly on the content's right edge, 116).
      def draw_battle_row(c, a)
        back = a.respond_to?(:battle_row) && a.battle_row == Game::Battle::ROW_BACK
        draw_system_text c, 0, ROW_LABEL_LINE * LINE_H, c.width, LINE_H,
                         back ? ROW_BACK_LABEL : ROW_FRONT_LABEL, @skin, 0, 2
      end

      # Blit `actor`'s own FaceSet cell at the actor panel's top-left corner.
      # A no-op for an actor with no face graphic set or whose file failed to
      # load (the same "a missing portrait draws nothing" rule every other
      # face-drawing screen in this port uses), leaving just the text columns.
      def draw_actor_face(c, actor)
        name = actor.respond_to?(:face_name) ? actor.face_name : nil
        sheet = load_face_bitmap(name)
        return unless sheet
        index = actor.respond_to?(:face_index) ? (actor.face_index || 0) : 0
        src = Rect.new((index % 4) * FACE_SIZE, (index / 4) * FACE_SIZE,
                       FACE_SIZE, FACE_SIZE)
        c.blt 0, 0, sheet, src
      end

      def load_face_bitmap(name)
        return nil if name.nil? || name.empty?
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
      end
    end

  end
end
