class RPG2k
  module Scene
    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Item, Skill, Equip and Status each push their own
    # scene (Scene::ItemMenu / SkillMenu / EquipMenu / StatusMenu); Save opens
    # the file-select screen (Scene::SaveLoad, in :save mode) and End Game
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

      def update
        return drive_message if @message

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

      private

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
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
      end

      def select_command
        key, label = @commands[@index]
        case key
        when :item
          @parent.push Scene::ItemMenu.new(@parent, @state)
        when :skill
          @parent.push Scene::SkillMenu.new(@parent, @state)
        when :equip
          @parent.push Scene::EquipMenu.new(@parent, @state)
        when :status
          @parent.push Scene::StatusMenu.new(@parent, @state)
        when :save
          if @state.save_access
            @parent.push Scene::SaveLoad.new(@parent, @state, :save)
          else
            show_message("You cannot save right now.")
          end
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
