class RPG2k
  module Scene
    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Item, Save and Order act immediately; Skill, Equip,
    # Status and Row instead hand input focus to the party-status panel so the
    # player picks *which actor* first (UP/DOWN, confirmed with C) -- Skill/
    # Equip/Status then open the corresponding scene (Scene::SkillMenu /
    # EquipMenu / StatusMenu) for that one, while Row instead toggles the
    # picked actor's front/back row right there and returns to the command
    # list without opening anything -- ported from a reference implementation,
    # where all four cases share this one actor-selection panel (there is no
    # separate handler for the Row toggle; it is inline in that same
    # actor-selection switch). All four are now confirmed on genuine
    # RPG_RT.exe under wine: Skill/Equip in cycle #240 (Nepheshel, RPG2000)
    # and the RPG2003-only Status/Row in cycle #256 (kk1.12 + the official
    # RTP -- its own menu offers both). Both pairs behave the same way: they
    # hand focus to the party list
    # first, a second Return opens the screen, and Escape from that screen
    # lands back on the command list with the cursor still on the command,
    # never on the actor-selection state -- see #leave_actor_selection.
    # Order -- which acts on the whole party at once, not one actor -- pushes
    # Scene::Order directly instead, the same `UpdateCommand` shape Item/Save
    # already use. Cancelling back out of actor selection returns focus to
    # the command list (confirmed the same way). End Game opens a Yes/No
    # confirmation (see #open_end_game_confirm); only confirming "Yes" there
    # returns to the title. Any further command (there are none left in the
    # built command list today) falls back to a "not implemented yet"
    # message.
    class Menu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # Width of the command list (top-left) and the Gold window (bottom-
      # left, see GOLD_WINDOW_W) -- independently pixel-measured against a
      # genuine `RPG_RT.exe` frame (Nepheshel, wine): both windows' right
      # borders land at the exact same x, forming one continuous column with
      # the party status panel filling the rest of the screen beside them.
      # The command window used to hardcode a bare, uncited `108` here --
      # 20px too wide, visibly misaligning it against the Gold window
      # directly beneath it.
      LEFT_COLUMN_W = 88

      # RPG2000's field menu is a *fixed* five commands with no separate Status
      # entry regardless of database content (a per-actor status readout has
      # no screen of its own in RPG2000; the party list already shown here is
      # what stands in for it, and Equip already shows the full stat block).
      # Independently confirmed against a genuine RPG_RT.exe under wine
      # (cycle #122): Nepheshel (RPG2000, no `menu_commands` chunk) draws
      # exactly five command rows for a solo party, wrapping Down from the
      # fifth back to the first -- Item / Skill / Equip, then a *blank* row
      # (Nepheshel's own `battle_save` Term, id 110, is the empty string --
      # confirmed by reading `RPG_RT.ldb` chunk 21 directly -- yet RPG_RT
      # still draws the row, just with no label, so Save is unconditionally
      # present, only its text is missing) and a fifth non-blank row (End
      # Game). No sixth row exists to scroll to. This was previously cited
      # only to a reference implementation's own command-window construction
      # path (Item/Skill/Equipment/Save/Quit, unconditional); that reference
      # is now redundant, not load-bearing.
      # RPG2003 replaces this fixed list with the System database's own
      # customizable one -- see RPG2K3_COMMAND_IDS below -- so this constant
      # is the RPG2000 (and RPG2003-without-a-menu_commands-chunk) default.
      RPG2K_COMMAND_KEYS = [
        [:item, :battle_item],
        [:skill, :battle_skill],
        [:equip, :battle_equipment],
        [:save, :battle_save],
        [:end_game, :battle_end_game]
      ].freeze

      # RPG2003's System chunk 22 field 27 (`menu_commands`, schema.rb) lists
      # the game's own command ids in the order the editor's "menu order" tab
      # arranges them -- matching a reference implementation's own command-id
      # enum (Item=1, Skill=2, Equipment=3, Save=4, Status=5, Row=6, Order=7,
      # Wait=8; Quit=9 is never itself in the list -- that implementation
      # appends it unconditionally after the loop, which #build_commands
      # mirrors below). Row (id 6, the
      # battle front/back toggle) is modelled the same actor-selection-panel
      # way Skill/Equipment/Status are (see the class comment) -- picking an
      # actor there flips `Game::Actor#battle_row` via `Game::Party
      # #toggle_actor_row`, the field-menu counterpart to the in-battle Row
      # command's `Game::Battle#toggle_row` (`scene/battle.rb`, ADR 0053).
      # Wait (id 8) *is* modelled: it flips the
      # save-system `atb_mode` toggle (LSD chunk 140) that makes a gauge
      # battle's command menu freeze (wait) or keep running (active) -- the
      # Wait-off (active) mode follow-up ADR 0054 named -- and its label
      # shows the *current* mode via the `wait_on` / `wait_off` terms, ported
      # from a reference implementation's own Wait row (a mode-check
      # expression selecting wait_on : wait_off), and #select_command's :wait
      # branch relabels it after
      # flipping. Order (party reordering, id 7) is also modelled -- unlike
      # Row it has no battle-system dependency at all, just Game::Party#
      # reorder and Scene::Order (see #select_command's :order branch). A real
      # RPG2003 game's array (mtf-meido-action's is `[1, 2, 3, 4, 5, 6, 7, 8]`,
      # confirmed by `db.rpg2003?` and reading chunk 22 by id under the CRuby
      # host harness, where `db.system` itself collides with Kernel#system)
      # can both omit a command (hiding it, e.g. a game with no Save on
      # principle) and reorder the survivors, both of which #build_commands
      # honours. **Confirmed against a genuine RPG2003 RPG_RT.exe under wine
      # (2026-09-06, kk1.12 + the official RTP -- see rtp_2003_install.bash):**
      # kk1.12's own `menu_commands` is `[1, 2, 5, 3, 6, 8, 4]`, and its real
      # field menu read, top to bottom, exactly Item/Skill/Status/Equip/Row/
      # Wait/Save (End Game appended below), matching this table id-for-id.
      # Status itself opened cleanly from that row with no error -- the
      # Scene::StatusMenu reachability question a much earlier cycle (#122)
      # closed as "structurally unreachable with any fixture this session
      # has" (no genuine RPG2003 `RPG_RT.exe` existed yet) is resolved: it is
      # reachable, and works.
      # **Order (id 7) is confirmed too (cycle #256)**, the one id no game
      # here lists: rewriting a scratch *copy* of kk1.12's own `RPG_RT.ldb`
      # to `[1, 2, 5, 3, 6, 8, 4, 7]` (field 26 to 8) through this project's
      # LCF writer made the genuine runtime draw a ninth row between Save and
      # End Game -- blank-labelled, since kk1.12's `order` term is the empty
      # string, and drawn anyway (the same "an empty term still gets its row"
      # rule Nepheshel's blank Save row established) -- and choosing it
      # opened the real Order screen (see Scene::Order). So the list is
      # honoured id-for-id and position-for-position, End Game always last.
      RPG2K3_COMMAND_IDS = {
        1 => [:item, :battle_item],
        2 => [:skill, :battle_skill],
        3 => [:equip, :battle_equipment],
        4 => [:save, :battle_save],
        5 => [:status, :status],
        6 => [:row, :row],
        7 => [:order, :order],
        8 => [:wait, :wait]
      }.freeze

      # bc2cpp: (, Game::State)
      def initialize parent, state
        super parent
        @state = state
        @index = 0
        @focus = :command       # :command (command list) or :actors (party-status panel)
        @actor_index = 0
        @pending_key = nil      # which command actor selection is for (:skill/:equip/:status)
        @message = nil
        @skin = make_windowskin
        @background = build_field_background(@skin)
        @commands = build_commands
        # yado.tk: opening the Menu (Save included — it has no scene of its own,
        # see the :save command below) auto-cancels an Erase Screen black-out
        # with no "Show Screen" involved, and RPG_RT never restores it when the
        # menu closes. An instant cut rather than #show's default fade, since
        # this snap happens the moment the menu opens, not over 35 frames.
        @state.screen.show(Game::Transition::CUT_IN, 0)
        build_windows
      end

      def dispose
        close_message
        @confirm_help.dispose if @confirm_help
        @confirm_command.dispose if @confirm_command
        @background.dispose if @background
        @command.dispose if @command
        @status.dispose if @status
        @gold.dispose if @gold
      end

      # Hide this menu's own command list and status panel while a child
      # screen (Item/Skill/Equip/Status) sits on top -- called by
      # RPG2k#push. None of those screens build a background of their own
      # (see Scene::Base#build_field_background's comment); they rely on
      # this menu's `@background` staying up to cover the map, but its two
      # windows must go, or they show through around/behind whatever the
      # child draws. Confirmed against genuine RPG_RT under wine: its own
      # Item screen shows only its own item-list window, nothing else.
      def suspend
        @command.visible = false if @command
        @status.visible = false if @status
        @gold.visible = false if @gold
      end

      # Undo #suspend once the child screen above this menu is popped and it
      # is active again -- called by RPG2k#pop, and by
      # #close_end_game_confirm, which hides the same three windows behind
      # the End Game prompt (see #open_end_game_confirm). Redraws the gold
      # panel too, ported from a reference implementation's own menu-resume
      # path, NOT independently confirmed against genuine RPG_RT under wine:
      # it unconditionally calls `gold_window->Refresh()` (alongside the
      # status panel's own `menustatus_window->Refresh()`, already mirrored
      # by #refresh_status_cursor/rebuilds elsewhere) every time control
      # returns from a popped child screen.
      def resume
        @command.visible = true if @command
        @status.visible = true if @status
        if @gold
          @gold.visible = true
          draw_gold_window
        end
      end

      def update
        # Every live window needs its own #update called every frame to
        # advance its selection-cursor blink (RPG2k::Window#update, gated on
        # `active` -- see its own citation) -- this scene never called it at
        # all, so every cursor here (command list, party-status panel, the
        # End Game confirm prompt) sat frozen on its first frame instead of
        # blinking the way every other window-driven screen in this codebase
        # does (Scene::Title's own #update already does this for its one
        # window).
        @command.update if @command
        @status.update if @status
        @gold.update if @gold
        @confirm_help.update if @confirm_help
        @confirm_command.update if @confirm_command
        return drive_message if @message
        case @focus
        when :actors then update_actor_selection
        when :end_game_confirm then update_end_game_confirm
        else update_command
        end
      end

      private

      # Holding Down/Up auto-repeats the cursor after the initial delay, not
      # just a single step per tap -- `Input.repeat?`'s own timing (this
      # build's own `mruby-rgss/mrblib/lib.rb`) is independently measured
      # against the genuine RPG_RT.exe under wine: holding a direction on a
      # title/menu cursor moves once immediately, then again after 24
      # frames, then every 4 frames after that -- see `Scene::SaveLoad`'s
      # own identical fix and its fuller writeup in docs/TODO.md for the
      # frame-by-frame confirmation -- so every `#trigger?` check below just
      # gains an `|| #repeat?` alongside it, the same pure-wiring shape.
      def update_command
        if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @index += 1
          @index %= @commands.size
          refresh_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @index -= 1
          @index %= @commands.size
          refresh_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::C)
          select_command
        end
      end

      # Picking who Skill/Equip/Status applies to, on the party-status panel
      # -- see the class comment. Entered by #select_command, left either by
      # cancelling back to the command list or by successfully opening the
      # chosen scene.
      def update_actor_selection
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_actor_selection
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @actor_index += 1
          @actor_index %= party.size
          refresh_status_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @actor_index -= 1
          @actor_index %= party.size
          refresh_status_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          confirm_actor_selection
        end
      end

      def confirm_actor_selection
        actor = @state.party.actors[@actor_index]
        # A currently-restricted actor (asleep/paralysed) cannot be given a
        # Skill command at all -- ported from a reference implementation's
        # own actor-selection handling, NOT independently confirmed against
        # genuine RPG_RT under wine: its Skill case alone gates on the
        # actor's ability to act; Equip/Status have no such gate. Checked first,
        # and left in actor-selection focus on failure (matching that same
        # actor-selection handling's own early return there, buzzer instead
        # of decision), so the player can simply pick someone else.
        if @pending_key == :skill && !actor.can_act?
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        key, index = @pending_key, @actor_index
        leave_actor_selection
        case key
        when :skill  then @parent.push Scene::SkillMenu.new(@parent, @state, index)
        when :equip  then @parent.push Scene::EquipMenu.new(@parent, @state, index)
        when :status then @parent.push Scene::StatusMenu.new(@parent, @state, index)
        when :row
          # No sub-scene: it toggles the picked actor's row right on the
          # actor-selection panel and falls straight back to the command
          # list, playing Decision regardless of whether the toggle actually
          # took (`Game::Party#toggle_actor_row` silently no-ops a refused
          # one -- see its own comment on the "don't empty the front row"
          # guard). **Confirmed against a genuine RPG2003 RPG_RT.EXE under
          # wine (cycle #256, kk1.12 + the official RTP):** Return on a
          # member of the party list redrew the menu with that member's
          # portrait indented 8px to the right (the back-row marker in
          # RPG_RT's own party panel: the leader's face moved from screen
          # x=92 to x=100, nothing else on the row moving) and with no actor
          # cursor left, i.e. straight back to the command list. Re-entering
          # Row started the party cursor at the first member again, never
          # where it had been. The refusal is real too, not just this port's
          # invention: with two of three members already in the back row,
          # Return on the last front-row member changed nothing at all, and
          # the same member moved as soon as somebody else was put back in
          # front.
          @state.party.toggle_actor_row(actor) if @state.party.respond_to?(:toggle_actor_row)
        end
      end

      # Back to the command list, cursor still on the command that started
      # the selection, and the party-status panel's own cursor gone --
      # confirmed on genuine RPG_RT.exe under wine (cycle #240), both for a
      # plain cancel here and for cancelling out of the Skill/Equip screen
      # opened from here: either way the next frame is the field menu with
      # the command cursor on 特殊技能/装備 and no actor cursor (a third
      # Escape then closes the menu to the map, and re-opening it starts on
      # アイテム again -- the cursor position is not remembered across a
      # close, which a fresh Scene::Menu per open already gives).
      def leave_actor_selection
        @focus = :command
        @pending_key = nil
        @command.active = true if @command
        @status.active = false if @status
      end

      # The command list this menu shows, in order: RPG2000's fixed five, or
      # RPG2003's customizable subset (plus an unconditional End Game at the
      # tail, matching a reference implementation's own unconditional Quit
      # push, not independently confirmed against genuine RPG_RT under wine)
      # -- see the two constants above for the reference this ports. `db.rpg2003?` is nil
      # (falsy) on the RPG2000-shaped fixtures the scene-check harness builds,
      # which is the correct reading for them too: they carry no `menu_commands`
      # chunk any more than a genuine RPG2000 database does.
      #
      # The Wait command's label is live: it shows the *current* active-time
      # mode (`wait_on` when wait, `wait_off` when active), the same reading
      # a reference implementation's own menu uses, so the row the player
      # just picked reads
      # "Wait On" while they are about to turn wait mode *off*. Confirmed
      # against a genuine RPG2003 RPG_RT.exe under wine (2026-09-06, kk1.12 +
      # the official RTP): a fresh save (`atb_mode` unset, so 0/active) and a
      # second save with `atb_mode` forced to 1 rendered the Wait row as
      # kk1.12's own `wait_off`/`wait_on` term text respectively -- the two
      # terms differ only in a trailing "/Active" vs. "/Wait", which is this
      # project's own term content, not something RPG_RT synthesizes, but the
      # *selection* (which whole term string shows for which raw atb_mode
      # value) matches this method exactly in both directions.
      def build_commands
        keys = if db.rpg2003?
                 ids = db.system.menu_commands || []
                 ids.filter_map { |id| RPG2K3_COMMAND_IDS[id] } << RPG2K_COMMAND_KEYS.last
               else
                 RPG2K_COMMAND_KEYS
               end
        keys.map { |key, term_name| [key, wait_term_for(key, term_name)] }
      end

      # The label for a command row: the Wait row is dynamic (the current
      # mode's term), every other row is a plain Term lookup.
      # bc2cpp: (Symbol, )
      def wait_term_for(key, term_name)
        return wait_label if key == :wait
        term(term_name)
      end

      # The Wait command row's label: `wait_on` while the fight is set to
      # pause on its command menu (wait mode, raw `atb_mode` 1), `wait_off`
      # once it is active (raw 0, the default) -- ported from a reference
      # implementation's own Wait row: a mode-check expression selecting
      # wait_on : wait_off. Confirmed against genuine RPG_RT.exe under wine
      # (2026-09-06, kk1.12 + the official RTP) -- see #build_commands, and
      # confirmed again live in cycle #256, this time by *toggling* rather
      # than by preparing two saves: a fresh save's row read kk1.12's
      # `wait_off` (ﾊﾞﾄﾙ/Active), one Return on it redrew that row alone as
      # `wait_on` (ﾊﾞﾄﾙ/Wait), and a second Return restored the first frame
      # pixel for pixel (see #select_command's :wait branch).
      def wait_label
        @state.atb_mode == 1 ? term(:wait_on) : term(:wait_off)
      end

      def build_windows
        cw = LEFT_COLUMN_W
        @command = Window.new(0, 0, cw, @commands.size * LINE_H + Window::BORDER * 2)
        @command.z = 400
        @command.windowskin = @skin
        cc = Bitmap.new(cw - Window::BORDER * 2, @commands.size * LINE_H)
        draw_command_labels(cc)
        @command.contents = cc
        refresh_cursor

        @status = Window.new(cw, 0, SCREEN_W - cw, SCREEN_H)
        @status.z = 400
        @status.windowskin = @skin
        sc = Bitmap.new(SCREEN_W - cw - Window::BORDER * 2, SCREEN_H - Window::BORDER * 2)
        sc.font.color = Color.new(255, 255, 255, 255)
        @state.party.actors.each_with_index do |a, i|
          y = i * STATUS_ROW_H
          draw_actor_face sc, a, 0, y
          draw_status_row sc, a, y
        end
        @status.contents = sc
        # No cursor of its own until Skill/Equip/Status hands it focus (see
        # #enter_actor_selection) -- an inactive window now hides its cursor
        # outright (RPG2k::Window#draw_cursor, see its own citation) rather
        # than leaving a stale highlight frozen in place.
        @status.active = false

        build_gold_window
      end

      # The party's own Gold, bottom-left corner -- ported from a reference
      # implementation's source, NOT independently confirmed against genuine
      # RPG_RT under wine: it creates a Gold window there unconditionally
      # (88x32, no version or feature gate anywhere), for both RPG2000 and
      # RPG2003 alike, drawing the amount then the `gold` term -- the
      # identical no-space "amount then term"
      # rendering `Scene::StatusMenu`'s own Gold line already uses. Its
      # width is the same `LEFT_COLUMN_W` the command list above it uses --
      # see that constant's own citation.
      GOLD_WINDOW_W = LEFT_COLUMN_W
      GOLD_WINDOW_H = 32

      def build_gold_window
        @gold = Window.new(0, SCREEN_H - GOLD_WINDOW_H, GOLD_WINDOW_W, GOLD_WINDOW_H)
        @gold.z = 400
        @gold.windowskin = @skin
        draw_gold_window
      end

      # Amount then the `gold` term as one run right-aligned to the contents'
      # right edge, the term in the system colour (index 1) and the amount in
      # the default colour -- pixel-measured on genuine RPG_RT.exe under wine
      # (Nepheshel, cycle #240): with 0 gold the window reads `0Ｇ` ending
      # flush at the contents' right edge (Nepheshel's term is the
      # full-width Ｇ, U+FF27, a 12px glyph: the `0` cell sits at contents
      # x 54..60 and the Ｇ at 60..72), the Ｇ's pixels sampling the
      # skin's index-1 blue swatch and the digit index 0's white. This used
      # to be one flat-white `draw_text` run left-aligned at x 0.
      def draw_gold_window
        inner_w = GOLD_WINDOW_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        unit = term(:gold)
        unit_w = c.text_size(unit).width
        draw_system_text c, 0, 0, inner_w - unit_w, LINE_H,
                         @state.party.gold.to_s, @skin, 0, 2
        draw_system_text c, 0, 0, inner_w, LINE_H, unit, @skin, LABEL_COLOR, 2
        @gold.contents = c
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
      end

      # Party-status panel layout, in the panel's contents coordinates (the
      # panel is the 232x240 window at x=88, so its contents are 216 wide
      # starting at screen x=96). Every number here is pixel-measured on a
      # genuine RPG_RT.exe under wine (Nepheshel, town map 16, cycle #240),
      # from the leftmost glyph pixel of each run on 2x captures -- the
      # runtime's own latin glyphs start at column 0 of their 6px cell, so a
      # run's first pixel *is* its column -- checked on three saves: the
      # genuine max-level leader (LV50, 600/600) and two edited copies
      # (LV45 300000 EXP 60/480 HP 6/480 MP; LV20 16000 EXP), which is what
      # separates a fixed column from a right-aligned field:
      #
      #   line 1 (y 0):  name                              at x 56
      #   line 2 (y 16): "LV" x 56, level right after it (x 68 = 56 + the
      #                  2-char label's 12px), condition at x 98,
      #                  "HP" x 162, current HP right-aligned in [174,192)
      #                  ("600" starts at 174, "60" at 180), "/" at 192,
      #                  max HP at 198
      #   line 3 (y 32): "EX" x 56, current EXP right-aligned in [68,104)
      #                  ("300000" starts at 68, "16000" at 74), "/" at 104,
      #                  next level's EXP right-aligned in [110,146)
      #                  ("17xxx" at 116), "MP" x 162 and the MP figures in
      #                  the exact same columns as HP
      #
      # Three 16px lines per member, no fourth: the name sits alone on the
      # first line, EXP has the third line to itself beside MP. The LV/EX/
      # HP/MP labels draw in the System palette's colour 1 (the windowskin's
      # "system" blue -- the capture's label pixels sample the skin's index-1
      # swatch gradient, 130/170/255 down to 25/56/141, while every value,
      # the name and a normal condition sample index 0's white-to-blue), the
      # current HP/MP figure alone through #value_font_color (the edited
      # save's 60/480 HP and 6/480 MP both drew in the index-4 yellow
      # swatch, so the quarter-of-max critical rule holds on genuine RPG_RT
      # too). At the maximum level both EXP fields read six dashes
      # (`------/------`) -- exactly filling their 6-cell fields -- instead
      # of any number; below it the current EXP is the raw total and the
      # right-hand figure is the *absolute* threshold of the next level
      # (LV45 with 300000 EXP showed 349310, LV20 with 16000 showed a 5-digit
      # 17xxx -- the total needed, not the remaining 49310), the same
      # reading `Game::Actor#next_level_exp` gives. Glyph tops sit 4px below
      # each line's top (kana and digits alike), which the 16px-tall draw
      # rects reproduce for this engine's own font: `Bitmap#draw_text`
      # centres the 12px shinonome cell in the rect it is given, so a 16px
      # line puts the cell 2px below the line's top all by itself (cycle
      # #248 -- these rows used to add that 2px by hand).
      STATUS_TEXT_X = 56
      STATUS_LEVEL_X = 68
      STATUS_STATE_X = 98
      STATUS_STAT_LABEL_X = 162
      STATUS_STAT_CUR_X = 174
      STATUS_STAT_CUR_W = 18
      STATUS_STAT_SLASH_X = 192
      STATUS_STAT_MAX_X = 198
      STATUS_EXP_CUR_X = 68
      STATUS_EXP_FIELD_W = 36
      STATUS_EXP_SLASH_X = 104
      STATUS_EXP_NEXT_X = 110
      STATUS_MAX_LEVEL_EXP = '------'
      # System-palette index of the LV/EX/HP/MP labels (see above).
      LABEL_COLOR = 1

      def draw_status_row(sc, a, y)
        w = sc.width
        line = ->(n) { y + n * LINE_H }
        draw_system_text sc, STATUS_TEXT_X, line.call(0), w - STATUS_TEXT_X, LINE_H,
                         a.name.to_s, @skin
        y2 = line.call(1)
        draw_system_text sc, STATUS_TEXT_X, y2, w - STATUS_TEXT_X, LINE_H,
                         term(:level_short), @skin, LABEL_COLOR
        draw_system_text sc, STATUS_LEVEL_X, y2, w - STATUS_LEVEL_X, LINE_H,
                         a.level.to_s, @skin
        draw_actor_state sc, a, STATUS_STATE_X, y2, w - STATUS_STATE_X, LINE_H, @skin
        draw_status_stat sc, y2, term(:hp_short), a.hp, a.display_max_hp, true
        y3 = line.call(2)
        draw_status_exp sc, a, y3
        draw_status_stat sc, y3, term(:mp_short), a.mp, a.display_max_mp, false
      end

      # One "HP cur/max" run in the panel's fixed columns (see the layout
      # comment above): label in the system colour, the current figure
      # right-aligned in its 3-cell field through #value_font_color, the
      # slash and max in the default colour.
      def draw_status_stat(sc, y, label, cur, max, can_knockout)
        w = sc.width
        draw_system_text sc, STATUS_STAT_LABEL_X, y, w - STATUS_STAT_LABEL_X, LINE_H,
                         label, @skin, LABEL_COLOR
        draw_system_text sc, STATUS_STAT_CUR_X, y, STATUS_STAT_CUR_W, LINE_H,
                         cur.to_s, @skin, value_font_color(cur, max, can_knockout), 2
        draw_system_text sc, STATUS_STAT_SLASH_X, y, w - STATUS_STAT_SLASH_X, LINE_H,
                         '/', @skin
        draw_system_text sc, STATUS_STAT_MAX_X, y, w - STATUS_STAT_MAX_X, LINE_H,
                         max.to_s, @skin
      end

      # The EXP line: label, then two right-aligned 6-cell fields either
      # side of a slash -- the raw total and the next level's absolute
      # threshold (`Game::Actor#next_level_exp`), or six dashes each once
      # there is no next level (see the layout comment above).
      def draw_status_exp(sc, a, y)
        w = sc.width
        nxt = a.next_level_exp
        cur_s, nxt_s = nxt.nil? ? [STATUS_MAX_LEVEL_EXP, STATUS_MAX_LEVEL_EXP] : [a.exp.to_s, nxt.to_s]
        draw_system_text sc, STATUS_TEXT_X, y, w - STATUS_TEXT_X, LINE_H,
                         term(:exp_short), @skin, LABEL_COLOR
        draw_system_text sc, STATUS_EXP_CUR_X, y, STATUS_EXP_FIELD_W, LINE_H, cur_s, @skin, 0, 2
        draw_system_text sc, STATUS_EXP_SLASH_X, y, w - STATUS_EXP_SLASH_X, LINE_H, '/', @skin
        draw_system_text sc, STATUS_EXP_NEXT_X, y, STATUS_EXP_FIELD_W, LINE_H, nxt_s, @skin, 0, 2
      end

      # RPG2000 FaceSet geometry: a 4x4 grid of 48x48 face cells. Matches
      # Scene::Map's own `FACE_SIZE` (message-window face graphics) exactly,
      # but kept as this scene's own copy rather than shared -- Scene::Map's
      # version supports the Change Face Graphic mirror flag this one has no
      # use for, and neither is `private` in a way the other could reach
      # cleanly. The text column beside the portrait is STATUS_TEXT_X (56,
      # measured -- see #draw_status_row), not a FACE_SIZE + margin sum.
      FACE_SIZE = 48

      # Load a FaceSet graphic by name, or nil for a blank name or a missing
      # file. Colour-keyed like the other character art: a FaceSet's
      # palette entry 0 is its background.
      def load_face_bitmap(name)
        return nil unless name && !name.empty?
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
      end

      # Blit `actor`'s own FaceSet cell at (x, y) -- the party-status panel
      # never drew a portrait at all before this (confirmed against a
      # genuine RPG_RT.exe screenshot: its own field-menu panel shows one
      # beside every member's name). A no-op for an actor with no face
      # graphic set or whose file failed to load, leaving just the text
      # columns #build_windows already draws.
      def draw_actor_face(bmp, actor, x, y)
        name = actor.respond_to?(:face_name) ? actor.face_name : nil
        sheet = load_face_bitmap(name)
        return unless sheet
        index = actor.respond_to?(:face_index) ? (actor.face_index || 0) : 0
        src = Rect.new((index % 4) * FACE_SIZE, (index / 4) * FACE_SIZE, FACE_SIZE, FACE_SIZE)
        bmp.blt x, y, sheet, src
      end

      # Redraw the command window's label list. The Wait row's label is live
      # (see #wait_label), so flipping the toggle (#select_command's :wait
      # branch) has to repaint it -- the same redraw a reference
      # implementation performs for the relabelled row, applied to
      # the whole list here since this engine draws the command window as one
      # bitmap rather than per-row windows. Clears and re-draws the existing
      # contents bitmap in place, so the window object and cursor stay put.
      def redraw_command_labels
        cc = @command.contents
        cc.clear
        draw_command_labels(cc)
        refresh_cursor
      end

      # Whether command `key`'s row should read the windowskin's own
      # *disabled* swatch instead of its default text colour -- ported
      # directly from a reference implementation's source, NOT independently
      # confirmed against genuine RPG_RT under wine: its command-window
      # construction disables Save on save access being off, Order on the
      # party having one or fewer actors, and every
      # other command (Item/Skill/Equipment/Status/Row) on
      # an empty party -- Wait/Quit/Settings/Debug are never
      # disabled. The exact same three gates `#select_command` above
      # already enforces as buzzer-and-refuse *behaviour*; this is only the
      # missing visual cue RPG_RT shows before the player even tries.
      def command_disabled?(key)
        case key
        when :save then !@state.save_access
        when :order then @state.party.actors.size <= 1
        when :item, :skill, :equip, :status, :row then @state.party.actors.empty?
        else false
        end
      end

      # Draw every command row into `cc`, in the windowskin's own default
      # text colour or its *disabled* swatch (system-colour index 3) per
      # `#command_disabled?` -- ported from a reference implementation's
      # source, NOT independently confirmed against genuine RPG_RT under
      # wine: its command-window drawing always renders a disabled row
      # through the windowskin's disabled-color swatch (index 3), the same
      # windowskin-blended path every
      # enabled row uses, not a hardcoded flat gray -- a custom windowskin
      # whose disabled swatch is tinted shows that tint on real RPG_RT, the
      # same rule already ported for `Scene::Title`'s Continue and
      # `Scene::SaveLoad`'s file rows. `draw_system_text`'s own no-windowskin
      # fallback (plain `draw_text` in the current font colour) still
      # supplies the flat gray when there is no skin to sample.
      def draw_command_labels(cc)
        @commands.each_with_index do |(key, label), i|
          y = i * LINE_H
          if command_disabled?(key)
            cc.font.color = Color.new(128, 128, 128, 255)
            draw_system_text cc, 0, y, cc.width, LINE_H, label, @skin, 3
          else
            cc.font.color = Color.new(255, 255, 255, 255)
            draw_system_text cc, 0, y, cc.width, LINE_H, label, @skin
          end
        end
      end

      # Height of one party-status row (see #build_windows's own `y = i *
      # STATUS_ROW_H`): three 16px lines (name; LV/condition/HP; EX/MP --
      # see #draw_status_row's layout comment), and the actor-selection
      # cursor's own height -- its green frame on genuine RPG_RT.exe under
      # wine (cycle #240) spans screen y 8..56 for the first member, i.e.
      # exactly the contents' first 48 rows.
      STATUS_ROW_H = 48
      # The actor-selection cursor's contents-space rect: from the text
      # column (STATUS_TEXT_X, 56) to the contents' right edge (216), not the
      # full contents width -- the same genuine capture's green frame runs
      # from screen x 148 to 316, which through Game::WindowCursor's 4px
      # overhang on each side (screen 96 + 56 - 4 = 148, 96 + 216 + 4 = 316)
      # is exactly that rect: the portrait column stays outside the frame.
      # This used to start at x 0, 56px too far left, over the portrait.
      STATUS_CURSOR_X = STATUS_TEXT_X
      STATUS_CURSOR_W = 160

      def refresh_status_cursor
        @status.cursor_rect =
          Rect.new(STATUS_CURSOR_X, @actor_index * STATUS_ROW_H, STATUS_CURSOR_W, STATUS_ROW_H)
      end

      # Hand input focus to the party-status panel so the player picks which
      # actor `key` (:skill/:equip/:status) applies to -- see the class
      # comment and #confirm_actor_selection. The command list keeps its own
      # cursor drawn on the chosen command meanwhile -- confirmed on genuine
      # RPG_RT.exe under wine (cycle #240): the frame captured in the
      # actor-selection state shows both the green frame around the party
      # member *and* the one still around 特殊技能 on the command list, so
      # the command window stays `active` (input is routed by `@focus`, not
      # by the window flag); it used to go inactive here, which
      # RPG2k::Window#draw_cursor renders as no cursor at all.
      # bc2cpp: (Symbol)
      def enter_actor_selection(key)
        @focus = :actors
        @pending_key = key
        @actor_index = 0
        @status.active = true
        refresh_status_cursor
      end

      # Which SE a command-list confirm plays -- Decision when the command
      # actually does something, Buzzer when it is confirmed but refused
      # outright, ported from a reference implementation's own per-branch
      # sound-effect dispatch (Item/Skill/Equipment/Status all gate on an empty
      # party the same way; Save gates on `save_access` instead), NOT
      # independently confirmed against genuine RPG_RT under wine.
      def select_command
        key, label = @commands[@index]
        case key
        when :item
          if @state.party.actors.empty?
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @parent.push Scene::ItemMenu.new(@parent, @state)
          end
        when :skill, :equip, :status, :row
          # Row shares the exact same empty-party gate as Skill/Equipment/
          # Status here -- a reference implementation's command-update logic
          # groups all four cases under one shared empty-party gate (buzzer
          # if empty, otherwise proceed and activate the actor panel); the
          # empty-party half is not measurable here (kk1.12's party is three
          # members from its very first menu on), but **Row's handing focus
          # to the actor panel is confirmed against a genuine RPG2003
          # RPG_RT.EXE under wine (cycle #256, kk1.12 + the official RTP)**:
          # choosing its 隊列変更 row put the selection cursor on the party
          # list exactly the way Status and Equip do, and a second Return
          # there toggled that one member's row and dropped straight back to
          # the command list with no actor cursor left (see
          # #confirm_actor_selection).
          # Unlike Order's `size <= 1` gate, a
          # single-member party's Row toggle is still meaningful (front vs.
          # back matters for a solo character), so it is not specially
          # blocked here.
          if @state.party.actors.empty?
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            enter_actor_selection(key)
          end
        when :order
          # Order acts on the whole party at once, so it opens Scene::Order
          # directly instead of the actor-selection panel -- **confirmed
          # against a genuine RPG2003 RPG_RT.EXE under wine (cycle #256:
          # kk1.12 + the official RTP, a scratch copy of its `menu_commands`
          # rewritten to carry id 7 -- see Scene::Order's own citation)**:
          # choosing the row replaced the whole menu with the two-column
          # Order screen in one step, with no party cursor in between.
          # Reordering a single-member (or empty) party is meaningless --
          # that `size <= 1` gate is ported from a reference implementation's
          # own command-update Order branch and remains NOT independently
          # confirmed against genuine RPG_RT under wine (shrinking a genuine
          # save's party list blackens RPG_RT on Continue, so no capture
          # could reach a solo party): it gates on the party having one or
          # fewer actors rather than the plain-empty check every other
          # command here uses.
          if @state.party.actors.size <= 1
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @parent.push Scene::Order.new(@parent, @state)
          end
        when :wait
          # The active-time Wait/active toggle: play the Decision SE, flip
          # `SaveSystem.atb_mode` (0 active <-> 1 wait) and relabel the row
          # to the now-current mode's term. The gauge battle scene reads the
          # same field (#atb_accumulating? in battle_rpg2k3.rb).
          # **Confirmed against a genuine RPG2003 RPG_RT.EXE under wine
          # (cycle #256, kk1.12 + the official RTP):** pressing Return on the
          # Wait row changed *nothing on screen but that row's own label* --
          # a whole-frame diff against the frame before the press came back
          # as a single band, y 92..101 x 38..74, exactly the label's own
          # changed glyph run (ﾊﾞﾄﾙ/Active -> ﾊﾞﾄﾙ/Wait; the shared ﾊﾞﾄﾙ/
          # prefix is pixel-identical). The screen stays on the menu, the
          # cursor stays on the Wait row, and a second press restored a
          # pixel-identical frame -- a plain two-state toggle with no scene
          # of its own.
          play_system_se(SFX_DECISION)
          @state.atb_mode = @state.atb_mode == 1 ? 0 : 1
          @commands[@index] = [:wait, wait_label]
          redraw_command_labels
        when :save
          # A disabled Save command (Change Save Access off) just refuses the
          # selection outright -- ported from a reference implementation's
          # own command-update handling, NOT independently confirmed against
          # genuine RPG_RT under wine: its disabled-Save branch plays the
          # buzzer SE and does nothing else, no message of any kind. This
          # engine drew a hardcoded English "You cannot save right now.",
          # the same class of gap the Item/Skill empty-list placeholders and
          # this screen's own bleed-through fix turned out to be, but this
          # one only needed removing -- there was nothing to source instead,
          # matching RPG2000's own Term table, which has no slot for it.
          if @state.save_access
            play_system_se(SFX_DECISION)
            @parent.push Scene::SaveLoad.new(@parent, @state, :save)
          else
            play_system_se(SFX_BUZZER)
          end
        when :end_game
          play_system_se(SFX_DECISION)
          open_end_game_confirm
        else
          show_message("#{label} is not implemented yet.")
        end
      end

      # End Game never quits outright -- it opens a Yes/No confirmation on
      # top of the command list. Confirmed directly against a genuine
      # RPG_RT.exe (Nepheshel, wine): opening the prompt from a fresh menu
      # shows the cursor already on "はい" (Yes), the top row -- not "No", as
      # an earlier, reference-implementation-sourced note here had wrongly
      # claimed (that finding was discarded; see docs/TODO.md). "Yes" defaulting first
      # matches this same menu's Inn Accept/Cancel prompt, whose cursor also
      # starts on the affirmative option.
      END_GAME_YES = 0
      END_GAME_NO = 1

      # The prompt replaces the field menu on screen rather than floating
      # over it -- confirmed on genuine RPG_RT.exe under wine (Nepheshel,
      # cycle #240): the End Game frame shows only the two prompt windows on
      # the bare skin background, with no command list, party-status panel
      # or Gold window anywhere behind them, and all three are back (cursor
      # still on the End Game row) the moment the prompt is cancelled.
      # #suspend/#resume already hide and restore exactly those three
      # windows for the pushed child screens, so they serve here too.
      def open_end_game_confirm
        @focus = :end_game_confirm
        @confirm_index = END_GAME_YES
        @command.active = false
        suspend
        build_end_game_confirm_windows
      end

      # Vertical gap between the prompt's help window and its Yes/No window
      # -- see #build_end_game_confirm_windows.
      END_GAME_GAP = LINE_H

      # The prompt text is the Term table's own end_game_confirm, falling
      # back to RPG_RT's own English default when the database leaves it
      # blank, same as every other #term lookup in this scene. Both windows
      # are sized to their own text and their rects pixel-measured on a
      # genuine RPG_RT.exe under wine (Nepheshel, cycle #240, from the
      # skin's frame lines on 2x captures): the help window is 160x32 at
      # (80, 72) -- the 12-character 終了してよろしいですか？ plus the 8px
      # border on each side, centred horizontally, its text drawn
      # left-aligned from the contents' left edge (glyphs start at screen x
      # 88), not centred -- and the はい/いいえ window is 52x48 at (134,
      # 120): the 3-character いいえ plus borders wide, two 16px rows tall,
      # also centred horizontally, and 16px *below* the help window's
      # bottom edge (104), the pair as a whole (32 + 16 + 48 = 96 tall)
      # sitting centred on the 240px screen. Its cursor is the full
      # contents width per row: the green frame spans screen x 138..182,
      # y 128..144 on はい and 144..160 on いいえ. Both texts carry the
      # shadow and the skin's colour-0 gradient like every other window's;
      # they used to be flat-white `draw_text`, and the Yes/No window used
      # to butt straight against the help window's bottom edge, 8px too
      # high for both windows.
      def build_end_game_confirm_windows
        measure = Bitmap.new 1, 1
        text = term(:end_game_confirm)
        text_w = measure.text_size(text).width
        labels = [term(:yes), term(:no)]
        label_w = labels.map { |l| measure.text_size(l).width }.max

        help_w = text_w + Window::BORDER * 2
        help_h = LINE_H + Window::BORDER * 2
        cmd_w = label_w + Window::BORDER * 2
        cmd_h = labels.size * LINE_H + Window::BORDER * 2
        help_x = (SCREEN_W - help_w) / 2
        help_y = (SCREEN_H - (help_h + END_GAME_GAP + cmd_h)) / 2
        @confirm_help = Window.new(help_x, help_y, help_w, help_h)
        @confirm_help.z = 500
        @confirm_help.windowskin = @skin
        hc = Bitmap.new(help_w - Window::BORDER * 2, LINE_H)
        hc.font.color = Color.new(255, 255, 255, 255)
        draw_system_text hc, 0, 0, hc.width, LINE_H, text, @skin
        @confirm_help.contents = hc

        cmd_x = (SCREEN_W - cmd_w) / 2
        cmd_y = help_y + help_h + END_GAME_GAP
        @confirm_command = Window.new(cmd_x, cmd_y, cmd_w, cmd_h)
        @confirm_command.z = 500
        @confirm_command.windowskin = @skin
        cc = Bitmap.new(cmd_w - Window::BORDER * 2, cmd_h - Window::BORDER * 2)
        cc.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |l, i|
          draw_system_text cc, 0, i * LINE_H, cc.width, LINE_H, l, @skin
        end
        @confirm_command.contents = cc
        refresh_end_game_cursor
      end

      def refresh_end_game_cursor
        @confirm_command.cursor_rect =
          Rect.new(0, @confirm_index * LINE_H, @confirm_command.contents.width, LINE_H)
      end

      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: Decision plays the Decision SE on
      # *either* option and only "Yes" goes anywhere -- fading the current
      # BGM over 400ms before handing off to
      # the title, the same call `interpreter.rb`'s Fade Out BGM (11710)
      # uses. "No" and Cancel are otherwise identical: both just close the
      # prompt back to the command list, no title, no BGM fade.
      def update_end_game_confirm
        if Input.trigger?(Input::DOWN) || Input.trigger?(Input::UP) ||
           Input.repeat?(Input::DOWN) || Input.repeat?(Input::UP)
          @confirm_index = (@confirm_index == END_GAME_YES) ? END_GAME_NO : END_GAME_YES
          refresh_end_game_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_end_game_confirm
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          if @confirm_index == END_GAME_YES
            RGSS::Audio.bgm_fade(400)
            @parent.return_to_title
          else
            close_end_game_confirm
          end
        end
      end

      def close_end_game_confirm
        @confirm_help.dispose if @confirm_help
        @confirm_command.dispose if @confirm_command
        @confirm_help = nil
        @confirm_command = nil
        @focus = :command
        resume
        @command.active = true if @command
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        close_message
      end

      def show_message(text)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

  end
end
