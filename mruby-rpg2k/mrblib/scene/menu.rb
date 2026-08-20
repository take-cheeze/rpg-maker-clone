class RPG2k
  module Scene
    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Item, Save and Order act immediately; Skill, Equip,
    # Status and Row instead hand input focus to the party-status panel so the
    # player picks *which actor* first (UP/DOWN, confirmed with C) -- Skill/
    # Equip/Status then open the corresponding scene (Scene::SkillMenu /
    # EquipMenu / StatusMenu) for that one, while Row instead toggles the
    # picked actor's front/back row right there and returns to the command
    # list without opening anything -- confirmed against EasyRPG's own
    # `Scene_Menu::UpdateCommand`/`UpdateActorSelection`, where all four cases
    # share this one actor-selection panel (there is no separate `Scene_Row`;
    # the Row toggle is inline in `UpdateActorSelection`'s own `switch`).
    # Order -- which acts on the whole party at once, not one actor -- pushes
    # Scene::Order directly instead, the same `UpdateCommand` shape Item/Save
    # already use. Cancelling back out of actor selection returns focus to
    # the command list. End Game opens a Yes/No confirmation (see
    # #open_end_game_confirm); only confirming "Yes" there returns to the
    # title. Any further command (there are none left in the built command
    # list today) falls back to a "not implemented yet" message.
    class Menu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # RPG2000's field menu is a *fixed* five commands with no separate Status
      # entry -- EasyRPG's `Scene_Menu::CreateCommandWindow`'s `Player::IsRPG2k()`
      # branch hardcodes exactly Item / Skill / Equipment / Save / Quit
      # regardless of database content (a per-actor status readout has no
      # screen of its own in RPG2000; the party list already shown here is
      # what stands in for it, and Equip already shows the full stat block).
      # RPG2003 replaces this fixed list with the System database's own
      # customizable one -- see RPG2K3_COMMAND_IDS below -- so this constant
      # is the RPG2000 (and RPG2003-without-a-menu_commands-chunk) default.
      RPG2K_COMMAND_KEYS = [
        [:item, :battle_item, "Item"],
        [:skill, :battle_skill, "Skill"],
        [:equip, :battle_equipment, "Equip"],
        [:save, :battle_save, "Save"],
        [:end_game, :battle_end_game, "End Game"]
      ].freeze

      # RPG2003's System chunk 22 field 27 (`menu_commands`, schema.rb) lists
      # the game's own command ids in the order the editor's "menu order" tab
      # arranges them -- matching EasyRPG's `CommandOptionType` enum (Item=1,
      # Skill=2, Equipment=3, Save=4, Status=5, Row=6, Order=7, Wait=8; Quit=9
      # is never itself in the list -- `Scene_Menu` appends it unconditionally
      # after the loop, which #build_commands mirrors below). Row (id 6, the
      # battle front/back toggle) is modelled the same actor-selection-panel
      # way Skill/Equipment/Status are (see the class comment) -- picking an
      # actor there flips `Game::Actor#battle_row` via `Game::Party
      # #toggle_actor_row`, the field-menu counterpart to the in-battle Row
      # command's `Game::Battle#toggle_row` (`scene/battle.rb`, ADR 0053).
      # Wait (id 8) *is* modelled: it flips the
      # save-system `atb_mode` toggle (LSD chunk 140) that makes a gauge
      # battle's command menu freeze (wait) or keep running (active) -- the
      # Wait-off (active) mode follow-up ADR 0054 named -- and its label
      # shows the *current* mode via the `wait_on` / `wait_off` terms, exactly
      # as EasyRPG's own Wait row does (`GetAtbMode() == wait ? wait_on :
      # wait_off`, and #select_command's :wait branch relabels it after
      # flipping). Order (party reordering, id 7) is also modelled -- unlike
      # Row it has no battle-system dependency at all, just Game::Party#
      # reorder and Scene::Order (see #select_command's :order branch). A real
      # RPG2003 game's array (mtf-meido-action's is `[1, 2, 3, 4, 5, 6, 7, 8]`,
      # confirmed by `db.rpg2003?` and reading chunk 22 by id under the CRuby
      # host harness, where `db.system` itself collides with Kernel#system)
      # can both omit a command (hiding it, e.g. a game with no Save on
      # principle) and reorder the survivors, both of which #build_commands
      # honours.
      RPG2K3_COMMAND_IDS = {
        1 => [:item, :battle_item, "Item"],
        2 => [:skill, :battle_skill, "Skill"],
        3 => [:equip, :battle_equipment, "Equip"],
        4 => [:save, :battle_save, "Save"],
        5 => [:status, :status, "Status"],
        6 => [:row, :row, "Row"],
        7 => [:order, :order, "Order"],
        8 => [:wait, :wait, "Wait"]
      }.freeze

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
      # is active again -- called by RPG2k#pop. Redraws the gold panel too,
      # matching EasyRPG's own `Scene_Menu::Continue` (`src/scene_menu.cpp`),
      # which unconditionally calls `gold_window->Refresh()` (alongside the
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
        return drive_message if @message
        case @focus
        when :actors then update_actor_selection
        when :end_game_confirm then update_end_game_confirm
        else update_command
        end
      end

      private

      # Holding Down/Up auto-repeats the cursor after the initial delay, not
      # just a single step per tap -- `Window_Selectable::Update`
      # (`src/window_selectable.cpp`), the base every real RPG2000 command
      # list is built on, falls through to `Input::IsRepeated` right after
      # its own `IsTriggered` check. `Input.repeat?`'s own timing (this
      # build's own `mruby-rgss/mrblib/lib.rb`) already matches EasyRPG's
      # `start_repeat_time`/`repeat_time` constants (`src/input.cpp`) exactly
      # -- see `Scene::SaveLoad`'s own identical fix and its fuller writeup
      # in docs/TODO.md for the frame-by-frame confirmation -- so every
      # `#trigger?` check below just gains an `|| #repeat?` alongside it,
      # the same pure-wiring shape.
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
        # Skill command at all -- confirmed against EasyRPG's own
        # `UpdateActorSelection`, whose Skill case alone gates on
        # `actor->CanAct()`; Equip/Status have no such gate. Checked first,
        # and left in actor-selection focus on failure (matching
        # `UpdateActorSelection`'s own early `return` there, buzzer instead
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
          # No sub-scene: EasyRPG's own Row case toggles the picked actor's
          # row right on the actor-selection panel and falls straight back to
          # the command list, playing Decision regardless of whether the
          # toggle actually took (`Game::Party#toggle_actor_row` silently
          # no-ops a refused one -- see its own comment on the "don't empty
          # the front row" guard).
          @state.party.toggle_actor_row(actor) if @state.party.respond_to?(:toggle_actor_row)
        end
      end

      def leave_actor_selection
        @focus = :command
        @pending_key = nil
        @command.active = true if @command
        @status.active = false if @status
      end

      # The command list this menu shows, in order: RPG2000's fixed five, or
      # RPG2003's customizable subset (plus an unconditional End Game at the
      # tail, matching EasyRPG's own unconditional `Quit` push) -- see the two
      # constants above for the reference this ports. `db.rpg2003?` is nil
      # (falsy) on the RPG2000-shaped fixtures the scene-check harness builds,
      # which is the correct reading for them too: they carry no `menu_commands`
      # chunk any more than a genuine RPG2000 database does.
      #
      # The Wait command's label is live: it shows the *current* active-time
      # mode (`wait_on` when wait, `wait_off` when active), the same reading
      # EasyRPG's own menu uses, so the row the player just picked reads
      # "Wait On" while they are about to turn wait mode *off*.
      def build_commands
        keys = if db.rpg2003?
                 ids = db.system.menu_commands || []
                 ids.filter_map { |id| RPG2K3_COMMAND_IDS[id] } << RPG2K_COMMAND_KEYS.last
               else
                 RPG2K_COMMAND_KEYS
               end
        keys.map { |key, term_name, fallback| [key, wait_term_for(key, term_name, fallback)] }
      end

      # The label for a command row: the Wait row is dynamic (the current
      # mode's term), every other row is a plain Term lookup.
      def wait_term_for(key, term_name, fallback)
        return wait_label if key == :wait
        term(term_name, fallback)
      end

      # The Wait command row's label: `wait_on` while the fight is set to
      # pause on its command menu (wait mode, raw `atb_mode` 1), `wait_off`
      # once it is active (raw 0, the default) -- confirmed against
      # EasyRPG's own `Scene_Menu` Wait row (`src/scene_menu.cpp`):
      # `GetAtbMode() == AtbMode_atb_wait ? wait_on : wait_off`.
      def wait_label
        @state.atb_mode == 1 ? term(:wait_on, 'Wait On') : term(:wait_off, 'Wait Off')
      end

      def build_windows
        cw = 108
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
          y = i * 40
          sc.draw_text 0, y, sc.width, 14, a.name.to_s
          # The condition rides on the name row, right-aligned. RPG_RT sits it
          # beside the level, but that row already carries HP and MP here and
          # this panel is only 196px wide, so it goes where there is room.
          draw_actor_state sc, a, 0, y, sc.width, 14, @skin, 2
          sc.draw_text 0, y + 16, sc.width, 14,
                       "#{term(:level_short, 'Lv')} #{a.level}  " \
                        "#{term(:hp_short, 'HP')} #{a.hp}/#{a.display_max_hp}  " \
                        "#{term(:mp_short, 'MP')} #{a.mp}/#{a.display_max_mp}"
        end
        @status.contents = sc
        # No cursor of its own until Skill/Equip/Status hands it focus (see
        # #enter_actor_selection) -- Window#draw_cursor draws nothing at all
        # while a window is inactive, the same mechanism the command list's
        # own cursor disappears through once focus leaves it.
        @status.active = false

        build_gold_window
      end

      # The party's own Gold, bottom-left corner -- confirmed against
      # RPG_RT's own live source: `Scene_Menu::Start` (`src/scene_menu.cpp`)
      # creates a `Window_Gold` there unconditionally (88x32, no version or
      # feature gate anywhere in the file), for both RPG2000 and RPG2003
      # alike. `Window_Gold::Refresh` (`src/window_gold.cpp`) draws the
      # amount then the `gold` term via `DrawCurrencyValue`
      # (`src/window_base.cpp`) -- the identical no-space "amount then term"
      # rendering `Scene::StatusMenu`'s own Gold line already uses.
      GOLD_WINDOW_W = 88
      GOLD_WINDOW_H = 32

      def build_gold_window
        @gold = Window.new(0, SCREEN_H - GOLD_WINDOW_H, GOLD_WINDOW_W, GOLD_WINDOW_H)
        @gold.z = 400
        @gold.windowskin = @skin
        draw_gold_window
      end

      def draw_gold_window
        inner_w = GOLD_WINDOW_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, LINE_H, "#{@state.party.gold}#{term(:gold, 'G')}"
        @gold.contents = c
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
      end

      # Redraw the command window's label list. The Wait row's label is live
      # (see #wait_label), so flipping the toggle (#select_command's :wait
      # branch) has to repaint it -- the same redraw EasyRPG's
      # `SetItemText(index, ...)` performs for the relabelled row, applied to
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
      # *disabled* swatch instead of its default text colour -- confirmed
      # directly against RPG_RT's live source: `Scene_Menu::
      # CreateCommandWindow` (`src/scene_menu.cpp`) disables Save on
      # `!GetAllowSave()`, Order on `GetActors().size() <= 1`, and every
      # other command (Item/Skill/Equipment/Status/Row) on
      # `GetActors().empty()` -- Wait/Quit/Settings/Debug are never
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
      # `#command_disabled?` -- confirmed against RPG_RT's live source:
      # `Window_Command::SetItemEnabled`/`DrawItem` (`src/window_command.cpp`)
      # always draws a disabled row through `Font::ColorDisabled` (swatch
      # index 3, `src/font.h`), the same windowskin-blended path every
      # enabled row uses, not a hardcoded flat gray -- a custom windowskin
      # whose disabled swatch is tinted shows that tint on real RPG_RT, the
      # same rule already ported for `Scene::Title`'s Continue and
      # `Scene::SaveLoad`'s file rows. `draw_system_text`'s own no-windowskin
      # fallback (plain `draw_text` in the current font colour) still
      # supplies the flat gray when there is no skin to sample.
      def draw_command_labels(cc)
        @commands.each_with_index do |(key, label), i|
          y = i * LINE_H + 2
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
      # 40`) -- the party-status panel's cursor cell spans one whole row.
      STATUS_ROW_H = 40

      def refresh_status_cursor
        @status.cursor_rect =
          Rect.new(0, @actor_index * STATUS_ROW_H, @status.contents.width, STATUS_ROW_H)
      end

      # Hand input focus to the party-status panel so the player picks which
      # actor `key` (:skill/:equip/:status) applies to -- see the class
      # comment and #confirm_actor_selection.
      def enter_actor_selection(key)
        @focus = :actors
        @pending_key = key
        @actor_index = 0
        @command.active = false
        @status.active = true
        refresh_status_cursor
      end

      # Which SE a command-list confirm plays -- Decision when the command
      # actually does something, Buzzer when it is confirmed but refused
      # outright, matching `Scene_Menu::UpdateCommand`'s own per-branch
      # `SePlay` calls (Item/Skill/Equipment/Status all gate on an empty
      # party the same way; Save gates on `save_access` instead).
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
          # Status here -- EasyRPG's `UpdateCommand` groups all four cases
          # under one `if (actors.empty()) Buzzer else { Decision; activate
          # the actor panel }` block. Unlike Order's `size <= 1` gate, a
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
          # Reordering a single-member (or empty) party is meaningless --
          # confirmed against EasyRPG's own `Scene_Menu::UpdateCommand`'s
          # `Order` branch, which gates on `GetActors().size() <= 1` rather
          # than the plain-empty check every other command here uses.
          if @state.party.actors.size <= 1
            play_system_se(SFX_BUZZER)
          else
            play_system_se(SFX_DECISION)
            @parent.push Scene::Order.new(@parent, @state)
          end
        when :wait
          # The active-time Wait/active toggle, ported from EasyRPG's own
          # `Scene_Menu::UpdateCommand` Wait branch: play the Decision SE,
          # flip `SaveSystem.atb_mode` (0 wait <-> 1 active), and relabel the
          # row to the other mode's term. The gauge battle scene reads the
          # same field (#atb_accumulating? in battle_rpg2k3.rb).
          play_system_se(SFX_DECISION)
          @state.atb_mode = @state.atb_mode == 1 ? 0 : 1
          @commands[@index] = [:wait, wait_label]
          redraw_command_labels
        when :save
          # A disabled Save command (Change Save Access off) just refuses the
          # selection outright -- confirmed against EasyRPG's own
          # Scene_Menu::UpdateCommand, whose disabled-Save branch plays the
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
      # top of the command list, matching EasyRPG's own `Scene_End` (pushed
      # by `Scene_Menu::UpdateCommand`'s `case Quit`, right after the
      # Decision SE #select_command already plays above). `Scene_End::
      # CreateCommandWindow` defaults the cursor to "No" (index 1) -- a
      # stray confirm press does not quit the game.
      END_GAME_YES = 0
      END_GAME_NO = 1

      def open_end_game_confirm
        @focus = :end_game_confirm
        @confirm_index = END_GAME_NO
        @command.active = false
        build_end_game_confirm_windows
      end

      # The prompt text is the Term table's own end_game_confirm
      # (`Scene_End::CreateHelpWindow`'s `exit_game_message`), falling back
      # to RPG_RT's own English default when the database leaves it blank,
      # same as every other #term lookup in this scene. Sized to its own
      # text the way Scene::Title sizes its command window (#initialize's
      # own `measure.text_size` -- Scene_End::CreateHelpWindow does the same
      # off Text::GetSize), rather than a fixed width.
      def build_end_game_confirm_windows
        measure = Bitmap.new 1, 1
        text = term(:end_game_confirm, 'Do you really want to quit?')
        text_w = measure.text_size(text).width

        help_w = text_w + Window::BORDER * 2
        help_h = LINE_H + Window::BORDER * 2
        help_x = (SCREEN_W - help_w) / 2
        help_y = (SCREEN_H - help_h - (2 * LINE_H + Window::BORDER * 2)) / 2
        @confirm_help = Window.new(help_x, help_y, help_w, help_h)
        @confirm_help.z = 500
        @confirm_help.windowskin = @skin
        hc = Bitmap.new(help_w - Window::BORDER * 2, LINE_H)
        hc.font.color = Color.new(255, 255, 255, 255)
        hc.draw_text 0, 0, hc.width, LINE_H, text
        @confirm_help.contents = hc

        labels = [term(:yes, 'Yes'), term(:no, 'No')]
        label_w = labels.map { |l| measure.text_size(l).width }.max
        cmd_w = label_w + Window::BORDER * 2
        cmd_h = labels.size * LINE_H + Window::BORDER * 2
        cmd_x = (SCREEN_W - cmd_w) / 2
        cmd_y = help_y + help_h
        @confirm_command = Window.new(cmd_x, cmd_y, cmd_w, cmd_h)
        @confirm_command.z = 500
        @confirm_command.windowskin = @skin
        cc = Bitmap.new(cmd_w - Window::BORDER * 2, cmd_h - Window::BORDER * 2)
        cc.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index { |l, i| cc.draw_text 0, i * LINE_H, cc.width, LINE_H, l }
        @confirm_command.contents = cc
        refresh_end_game_cursor
      end

      def refresh_end_game_cursor
        @confirm_command.cursor_rect =
          Rect.new(0, @confirm_index * LINE_H, @confirm_command.contents.width, LINE_H)
      end

      # Matches `Scene_End::vUpdate`: Decision plays the Decision SE on
      # *either* option and only "Yes" goes anywhere -- fading the current
      # BGM over 400ms (`Game_System::BgmFade(400)`) before handing off to
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
