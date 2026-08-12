class RPG2k
  module Scene
    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Save and End Game are wired up; the item/skill/equip/
    # status screens are placeholders that report they are not implemented.
    class Menu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # Command keys in menu order, paired with the database term (and its
      # RPG_RT-standard English fallback) that names each on screen.
      COMMAND_KEYS = [
        [:item, :battle_item, "Item"],
        [:skill, :battle_skill, "Skill"],
        [:equip, :battle_equipment, "Equip"],
        [:status, :status, "Status"],
        [:save, :battle_save, "Save"],
        [:end_game, :battle_end_game, "End Game"]
      ].freeze

      def initialize parent, state
        super parent
        @state = state
        @index = 0
        @message = nil
        @skin = make_windowskin
        @commands = COMMAND_KEYS.map { |key, term_name, fallback|
          [key, term(term_name, fallback)]
        }
        build_windows
      end

      def dispose
        close_message
        @command.dispose if @command
        @status.dispose if @status
      end

      def update
        return drive_message if @message

        if Input.trigger?(Input::DOWN) && @index < @commands.size - 1
          @index += 1
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @index > 0
          @index -= 1
          refresh_cursor
        elsif Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::C)
          select_command
        end
      end

      private

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
            show_message(@parent.save_game(@state) ? "Game saved." : "Save failed.")
          else
            show_message("You cannot save right now.")
          end
        when :end_game
          show_message("Returning to title...", :end_game)
        else
          show_message("#{label} is not implemented yet.")
        end
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        @parent.return_to_title if done == :end_game
      end

      def show_message(text, done = nil)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win, done: done }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

  end
end
