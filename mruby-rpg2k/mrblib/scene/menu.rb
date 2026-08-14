class RPG2k
  module Scene
    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Item and Save act immediately; Skill, Equip and
    # Status instead hand input focus to the party-status panel so the
    # player picks *which actor* first (UP/DOWN, confirmed with C) before
    # the corresponding scene (Scene::SkillMenu / EquipMenu / StatusMenu)
    # opens for that one -- confirmed against EasyRPG's own
    # `Scene_Menu::UpdateCommand`/`UpdateActorSelection` (`Skill`/
    # `Equipment`/`Status`/`Row` all share this shape; RPG2003's Row, the
    # battle front/back toggle, is not modelled here). Cancelling back out
    # of actor selection returns focus to the command list. End Game
    # returns to the title. Any further command (there are none left in the
    # built command list today) falls back to a "not implemented yet" message.
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
      # after the loop, which #build_commands mirrors below). Row (battle
      # front/back rank), Order (party reordering) and Wait (the ATB toggle)
      # have no entry here and are silently skipped: they are RPG2003
      # battle-system features this runtime does not model, the same
      # reported-gap precedent the Toggle ATB Mode (5003) event command
      # entry already establishes elsewhere. A real RPG2003 game's array
      # (mtf-meido-action's is `[1, 2, 3, 4, 5, 6, 7, 8]`, confirmed by
      # `db.rpg2003?` and reading chunk 22 by id under the CRuby host
      # harness, where `db.system` itself collides with Kernel#system) can
      # both omit a command (hiding it, e.g. a game with no Save on principle)
      # and reorder the survivors, both of which #build_commands honours.
      RPG2K3_COMMAND_IDS = {
        1 => [:item, :battle_item, "Item"],
        2 => [:skill, :battle_skill, "Skill"],
        3 => [:equip, :battle_equipment, "Equip"],
        4 => [:save, :battle_save, "Save"],
        5 => [:status, :status, "Status"]
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
        @background.dispose if @background
        @command.dispose if @command
        @status.dispose if @status
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
      end

      # Undo #suspend once the child screen above this menu is popped and it
      # is active again -- called by RPG2k#pop.
      def resume
        @command.visible = true if @command
        @status.visible = true if @status
      end

      def update
        return drive_message if @message
        @focus == :actors ? update_actor_selection : update_command
      end

      private

      def update_command
        if Input.trigger?(Input::DOWN)
          @index += 1
          @index %= @commands.size
          refresh_cursor
        elsif Input.trigger?(Input::UP)
          @index -= 1
          @index %= @commands.size
          refresh_cursor
        elsif Input.trigger?(Input::B)
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
          leave_actor_selection
        elsif Input.trigger?(Input::DOWN)
          @actor_index += 1
          @actor_index %= party.size
          refresh_status_cursor
        elsif Input.trigger?(Input::UP)
          @actor_index -= 1
          @actor_index %= party.size
          refresh_status_cursor
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
        # `UpdateActorSelection`'s own early `return` there), so the player
        # can simply pick someone else.
        return if @pending_key == :skill && !actor.can_act?
        key, index = @pending_key, @actor_index
        leave_actor_selection
        case key
        when :skill  then @parent.push Scene::SkillMenu.new(@parent, @state, index)
        when :equip  then @parent.push Scene::EquipMenu.new(@parent, @state, index)
        when :status then @parent.push Scene::StatusMenu.new(@parent, @state, index)
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
      def build_commands
        keys = if db.rpg2003?
                 ids = db.system.menu_commands || []
                 ids.filter_map { |id| RPG2K3_COMMAND_IDS[id] } << RPG2K_COMMAND_KEYS.last
               else
                 RPG2K_COMMAND_KEYS
               end
        keys.map { |key, term_name, fallback| [key, term(term_name, fallback)] }
      end

      def build_windows
        cw = 108
        @command = Window.new(0, 0, cw, @commands.size * LINE_H + Window::BORDER * 2)
        @command.z = 400
        @command.windowskin = @skin
        cc = Bitmap.new(cw - Window::BORDER * 2, @commands.size * LINE_H)
        cc.font.color = Color.new(255, 255, 255, 255)
        @commands.each_with_index do |(_key, label), i|
          cc.draw_text 0, i * LINE_H + 2, cc.width, LINE_H, label
        end
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
                       "#{term(:hp_short, 'HP')} #{a.hp}/#{a.max_hp}  " \
                       "#{term(:mp_short, 'MP')} #{a.mp}/#{a.max_mp}"
        end
        @status.contents = sc
        # No cursor of its own until Skill/Equip/Status hands it focus (see
        # #enter_actor_selection) -- Window#draw_cursor draws nothing at all
        # while a window is inactive, the same mechanism the command list's
        # own cursor disappears through once focus leaves it.
        @status.active = false
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
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

      def select_command
        key, label = @commands[@index]
        case key
        when :item
          @parent.push Scene::ItemMenu.new(@parent, @state)
        when :skill, :equip, :status
          enter_actor_selection(key) unless @state.party.actors.empty?
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
          @parent.push Scene::SaveLoad.new(@parent, @state, :save) if @state.save_access
        when :end_game
          @parent.return_to_title
        else
          show_message("#{label} is not implemented yet.")
        end
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
