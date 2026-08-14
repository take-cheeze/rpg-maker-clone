class RPG2k
  module Scene
    # The field skill screen (main menu -> Skill). Lists one party member's known
    # field-usable skills with their SP cost. Casting a single-ally skill
    # (scope 3) asks who to use it on, while a self (2) or all-ally (4) skill
    # applies at once, spending SP and restoring HP/SP. An Escape skill warps
    # straight to the registered escape target with no prompt; a Teleport
    # skill opens a third list of every registered destination (by map name)
    # to choose from. Either warp closes the whole menu stack and queues the
    # jump for Scene::Map to perform (see Game::State#pending_teleport)
    # rather than applying anything here. All the decision logic is on
    # Game::Party (field_skills / skill_cost / can_cast? / skill_effect /
    # cast_skill / cast_escape_skill / cast_teleport_skill), host-tested;
    # this is the RGSS UI over it.
    #
    # There is no way to switch caster once this screen is open -- confirmed
    # against EasyRPG Player's own source (`scene_skill.h`'s `actor_index`
    # is a constructor parameter `Scene_Skill::vUpdate` never changes,
    # unlike `Scene_Equip`'s own LEFT/RIGHT actor-switch). Real RPG_RT
    # instead hands input focus to the *menu's own party list* when Skill
    # is selected there, letting the player pick which actor first
    # (`Scene_Menu::UpdateCommand`'s `Skill`/`Equipment`/`Status`/`Row`
    # branch) -- `Scene::Menu#enter_actor_selection` now ports that, and
    # passes the chosen actor's index in here as the third constructor
    # argument (default 0, the leader, for callers that never had a picker
    # to begin with, e.g. the host test harnesses).
    class SkillMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # The skill list is a two-column grid, the same shape and cursor math
      # as Scene::ItemMenu's own (see its COLUMN_MAX comment) -- confirmed
      # via EasyRPG's `Window_Skill` constructor, which sets `column_max =
      # 2`. LEFT/RIGHT move within a row now that they are not needed for
      # caster-switching (see the class comment above).
      COLUMN_MAX = 2

      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @caster_index = actor_index
        @skill_index = 0
        @target_index = 0
        @teleport_index = 0
        @pending_skill = nil
        @mode = :skills          # :skills list, :target selection, or :teleport_target
        @message = nil
        build_skill_window
      end

      def dispose
        close_message
        @skill_window.dispose if @skill_window
        @target_window.dispose if @target_window
        @teleport_window.dispose if @teleport_window
      end

      def update
        return drive_message if @message
        case @mode
        when :target then update_target
        when :teleport_target then update_teleport_target
        else update_skills
        end
      end

      private

      def caster
        @state.party.actors[@caster_index]
      end

      def skills
        @skills ||= @state.party.field_skills(caster, @state)
      end

      def skill_name(sid)
        sk = @state.party.db_skill(sid)
        n = sk && sk.name.to_s
        n.nil? || n.empty? ? "Skill #{sid}" : n
      end

      def update_skills
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::DOWN)
          move_skill_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP)
          move_skill_cursor(-COLUMN_MAX)
        elsif Input.trigger?(Input::RIGHT)
          move_skill_cursor(1) if (@skill_index + 1) % COLUMN_MAX != 0
        elsif Input.trigger?(Input::LEFT)
          move_skill_cursor(-1) if @skill_index % COLUMN_MAX != 0
        elsif Input.trigger?(Input::C)
          choose_skill
        end
      end

      # Move the skill cursor by `delta` cells (a row for +-COLUMN_MAX, a
      # column for +-1), ignored if that cell is off the grid -- see
      # Scene::ItemMenu#move_item_cursor, which this mirrors exactly.
      def move_skill_cursor(delta)
        return if skills.empty?
        target = @skill_index + delta
        return if target < 0 || target >= skills.size
        @skill_index = target
        refresh_skill_cursor
      end

      def choose_skill
        return if skills.empty?
        sid, = skills[@skill_index]
        sk = @state.party.db_skill(sid)
        # A switch skill has no target at all; Escape warps straight to its one
        # registered target; Teleport opens a list of every registered target;
        # a self (2) or all-ally (4) skill needs no target prompt; a
        # single-ally skill (3) asks which ally.
        if sk && sk.type == Game::Party::SKILL_SWITCH
          apply_switch_skill(sid)
        elsif sk && sk.type == Game::Party::SKILL_ESCAPE
          apply_escape_skill(sid)
        elsif sk && sk.type == Game::Party::SKILL_TELEPORT
          @pending_skill = sid
          @mode = :teleport_target
          @teleport_index = 0
          build_teleport_window
        elsif sk && (sk.scope == 2 || sk.scope == 4)
          apply_skill(sid, nil)
        else
          @pending_skill = sid
          @mode = :target
          @target_index = 0
          build_target_window
        end
      end

      def update_target
        party = @state.party.actors
        if Input.trigger?(Input::B)
          leave_target
        elsif Input.trigger?(Input::DOWN)
          @target_index += 1
          @target_index %= party.size
          refresh_target_cursor
        elsif Input.trigger?(Input::UP)
          @target_index -= 1
          @target_index %= party.size
          refresh_target_cursor
        elsif Input.trigger?(Input::C)
          apply_skill(@pending_skill, party[@target_index])
        end
      end

      def apply_skill(sid, target)
        affected = @state.party.cast_skill(caster, sid, target)
        if affected.empty?
          show_message("It had no effect.")
        else
          show_message("#{caster.name} casts #{skill_name(sid)}!", :cast)
        end
      end

      # A switch skill (type 3) spends its SP and turns on a game switch, with
      # nothing to target. This is how a Nepheshel player summons and dismisses a
      # companion — the switch is what its common event watches.
      def apply_switch_skill(sid)
        switch = @state.party.cast_switch_skill(caster, sid)
        if switch
          @state.switches[switch] = true
          show_message("#{caster.name} casts #{skill_name(sid)}!", :cast)
        else
          show_message("It had no effect.")
        end
      end

      def leave_target
        @pending_skill = nil
        @mode = :skills
        if @target_window
          @target_window.dispose
          @target_window = nil
        end
      end

      def update_teleport_target
        targets = teleport_targets
        if Input.trigger?(Input::B)
          leave_teleport_target
        elsif Input.trigger?(Input::DOWN) && !targets.empty?
          @teleport_index += 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
        elsif Input.trigger?(Input::UP) && !targets.empty?
          @teleport_index -= 1
          @teleport_index %= targets.size
          refresh_teleport_cursor
        elsif Input.trigger?(Input::C) && !targets.empty?
          map_id, = targets[@teleport_index]
          apply_teleport_skill(@pending_skill, map_id)
        end
      end

      # Escape (type 1) warps to the single registered escape target with no
      # picker (see the class comment). A successful cast closes the whole menu
      # stack at once, matching RPG_RT: there is no field-menu message shown
      # afterwards, since the map that would show it is gone before the next
      # frame draws.
      def apply_escape_skill(sid)
        target = @state.party.cast_escape_skill(caster, sid, @state)
        if target
          queue_teleport(target)
        else
          show_message("It had no effect.")
        end
      end

      # Teleport (type 2), once a destination is chosen from the list built by
      # #build_teleport_window.
      def apply_teleport_skill(sid, map_id)
        target = @state.party.cast_teleport_skill(caster, sid, @state, map_id)
        if target
          queue_teleport(target)
        else
          show_message("It had no effect.")
        end
      end

      # Queue the warp for Scene::Map (see Game::State#pending_teleport) and pop
      # every menu on top of it in one step.
      def queue_teleport(target)
        @state.pending_teleport = [target[:map_id], target[:x], target[:y], 0]
        @parent.pop_to_map
      end

      def leave_teleport_target
        @pending_skill = nil
        @mode = :skills
        if @teleport_window
          @teleport_window.dispose
          @teleport_window = nil
        end
      end

      # After a successful cast, drop back to the skill list and rebuild it (SP
      # fell; a now-unaffordable skill drops out).
      def refresh_after_cast
        leave_target
        @skills = nil
        @skill_index = skills.size - 1 if @skill_index >= skills.size
        @skill_index = 0 if @skill_index < 0
        build_skill_window
      end

      # Column width for the skill grid (see Scene::ItemMenu#item_col_w,
      # which this mirrors).
      def skill_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      def build_skill_window
        @skill_window.dispose if @skill_window
        rows = skills
        inner_w = SCREEN_W - Window::BORDER * 2
        head_h = LINE_H
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = head_h + grid_rows * LINE_H
        @skill_window = Window.new(0, 0, SCREEN_W, h + Window::BORDER * 2)
        @skill_window.z = 400
        @skill_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = caster
        mp_term = term(:mp_short, 'MP')
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}   #{mp_term} #{a.mp}/#{a.max_mp}"
        # An empty skill list draws no placeholder text -- matching the fix
        # for the analogous Item screen (see item_menu.rb), confirmed there
        # against genuine RPG_RT under wine: a blank list row with a visible,
        # empty cursor box (see #refresh_skill_cursor) rather than a message.
        col_w = skill_col_w
        rows.each_with_index do |(sid, cost), i|
          x = (i % COLUMN_MAX) * col_w
          y = head_h + (i / COLUMN_MAX) * LINE_H
          c.draw_text x, y, col_w - 40, LINE_H, skill_name(sid)
          # "-  5"-style: a separator (a plain hyphen -- confirmed via
          # EasyRPG's own Window_Skill::DrawItem, which formats this as
          # `"{separator}{cost:3d}"` with a hyphen default) then the cost
          # right-aligned in a 3-character field, no MP/SP unit suffix.
          c.draw_text x + col_w - 40, y, 40, LINE_H, "-%3d" % cost
        end
        @skill_window.contents = c
        refresh_skill_cursor
      end

      def refresh_skill_cursor
        return unless @skill_window
        # The cursor box stays visible on the empty row even with no skills
        # -- see item_menu.rb's analogous fix. Highlights just the one grid
        # cell, not the full row -- see Scene::ItemMenu#refresh_item_cursor.
        x = (@skill_index % COLUMN_MAX) * skill_col_w
        y = LINE_H + (@skill_index / COLUMN_MAX) * LINE_H
        @skill_window.cursor_rect = Rect.new(x, y, skill_col_w, LINE_H)
      end

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = SCREEN_W - Window::BORDER * 2
        h = party.size * (LINE_H * 2)
        @target_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                    SCREEN_W, h + Window::BORDER * 2)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        party.each_with_index do |a, i|
          y = i * LINE_H * 2
          c.draw_text 0, y, inner_w, LINE_H, a.name.to_s
          # RPG_RT's target list shows each member's condition (its
          # Window_ActorTarget draws one) -- which is most of the point of the
          # list, since it is where you pick who to use an antidote on.
          draw_actor_state c, a, 0, y, inner_w, LINE_H, @skin, 2
          c.draw_text 0, y + LINE_H, inner_w, LINE_H,
                      "#{term(:hp_short, 'HP')} #{a.hp}/#{a.max_hp}  " \
                      "#{term(:mp_short, 'MP')} #{a.mp}/#{a.max_mp}"
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      def refresh_target_cursor
        return unless @target_window
        @target_window.cursor_rect =
          Rect.new(0, @target_index * LINE_H * 2, @target_window.contents.width,
                   LINE_H * 2)
      end

      # The registered teleport destinations as `[map_id, name]` pairs,
      # ascending by map id — the same order `Game::State#teleport_targets`
      # (a plain hash built by Set Teleport Target) already keeps them in, and
      # the same order EasyRPG's `Window_Teleport` lists them in (the order
      # `Game_Targets::GetTeleportTargets` returns, sorted by map id on insert).
      def teleport_targets
        @state.teleport_targets.keys.sort.map { |id| [id, map_display_name(id)] }
      end

      # A map's editor name for the teleport picker, or its bare id when the
      # tree carries no name for it (a bare fixture, or an id the tree does not
      # know) — matching EasyRPG's `Game_Map::GetMapName`, which reads the same
      # map-tree field this build's #map_properties elsewhere already exposes.
      def map_display_name(map_id)
        row = map_tree.respond_to?(:map_properties) ? map_tree.map_properties[map_id] : nil
        name = row && row.respond_to?(:name) ? row.name.to_s : nil
        name.nil? || name.empty? ? "Map #{map_id}" : name
      end

      def build_teleport_window
        @teleport_window.dispose if @teleport_window
        rows = teleport_targets
        inner_w = SCREEN_W - Window::BORDER * 2
        h = [rows.size, 1].max * LINE_H
        @teleport_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                      SCREEN_W, h + Window::BORDER * 2)
        @teleport_window.z = 450
        @teleport_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 0, inner_w, LINE_H, "No destinations"
        else
          rows.each_with_index do |(_id, name), i|
            c.draw_text 0, i * LINE_H, inner_w, LINE_H, name
          end
        end
        @teleport_window.contents = c
        refresh_teleport_cursor
      end

      def refresh_teleport_cursor
        return unless @teleport_window
        h = teleport_targets.empty? ? 0 : LINE_H
        @teleport_window.cursor_rect =
          Rect.new(0, @teleport_index * LINE_H, @teleport_window.contents.width, h)
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        refresh_after_cast if done == :cast
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
