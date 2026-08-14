class RPG2k
  module Scene
    # The field status screen (main menu -> Status). Shows one party member's full
    # detail -- name/title, level, EXP and EXP-to-next, HP/MP, the six stats and
    # the five equipment slots; LEFT/RIGHT cycle the member. Read-only, so there
    # is no sub-mode. The EXP-to-next figure is Game::Actor#exp_to_next
    # (host-tested); the rest reads existing accessors.
    class StatusMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # The condition row: which line of the panel it is, its label, and where
      # the state itself starts (clear of the label).
      STATE_ROW = 4
      STATE_LABEL = "State".freeze
      STATE_VALUE_X = 48

      # `actor_index` is which party member the screen opens on -- the one
      # `Scene::Menu#enter_actor_selection` preselected from the menu's own
      # party list (confirmed against EasyRPG's `Scene_Status` constructor,
      # which takes the same parameter), defaulting to 0 (the leader) for
      # callers that never had a picker to begin with, e.g. the host test
      # harnesses. LEFT/RIGHT still cycle from there once inside -- EasyRPG's
      # own `Scene_Status::vUpdate` does the same.
      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = actor_index
        @slots = [
          term(:weapon, "Weapon"), term(:shield, "Shield"), term(:armor, "Armor"),
          term(:helmet, "Helmet"), term(:accessory, "Accessory")
        ]
        build_window
      end

      def dispose
        @window.dispose if @window
      end

      def update
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          build_window
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::LEFT)
          @actor_index -= 1
          @actor_index %= party.size
          build_window
          play_system_se(SFX_CURSOR)
        end
      end

      private

      def item_name(id)
        return "-" if id.nil? || id == 0
        it = @state.party.db_item(id)
        n = it && it.name.to_s
        n.nil? || n.empty? ? "Item #{id}" : n
      end

      def build_window
        @window.dispose if @window
        inner_w = SCREEN_W - Window::BORDER * 2
        @window = Window.new(0, 0, SCREEN_W, SCREEN_H)
        @window.z = 400
        @window.windowskin = @skin
        c = Bitmap.new(inner_w, SCREEN_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        a = @state.party.actors[@actor_index]
        title = a.title.to_s
        header = title.empty? ? a.name.to_s : "#{a.name}  #{title}"
        nxt = a.exp_to_next
        lines = [
          header,
          "#{term(:level_short, 'Lv')} #{a.level}    " \
          "#{term(:exp_short, 'EXP')} #{a.exp}    Next #{nxt.nil? ? '---' : nxt}",
          "#{term(:hp_short, 'HP')} #{a.hp}/#{a.max_hp}    " \
          "#{term(:mp_short, 'MP')} #{a.mp}/#{a.max_mp}",
          "#{term(:attack, 'Atk')} #{a.atk}   #{term(:defense, 'Def')} #{a.def}   " \
          "#{term(:mind, 'Int')} #{a.int}   #{term(:agility, 'Agi')} #{a.agi}",
          # The condition gets a labelled row of its own, as on RPG_RT's status
          # screen (its Window_ActorInfo draws the label then the state). Only
          # the label goes through the flat pass below; the state itself is drawn
          # after it so it can take its own palette colour.
          STATE_LABEL,
          "",
        ]
        eqp = a.equipment
        @slots.each_with_index { |label, i| lines.push("#{label}: #{item_name(eqp[i])}") }
        lines.each_with_index do |line, i|
          c.draw_text 0, i * LINE_H, inner_w, LINE_H, line
        end
        draw_actor_state c, a, STATE_VALUE_X, STATE_ROW * LINE_H,
                         inner_w - STATE_VALUE_X, LINE_H, @skin
        @window.contents = c
      end
    end

  end
end
