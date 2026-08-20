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

      # Height of the skill-description banner at the very top of the screen
      # (see #build_desc_window) -- the same gap Scene::ItemMenu/EquipMenu
      # both already closed for their own description text; Scene::SkillMenu
      # never grew the equivalent Window_Help.
      DESC_H = LINE_H + Window::BORDER * 2

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
        @target_lock = nil
        @teleport_index = 0
        @pending_skill = nil
        @mode = :skills          # :skills list, :target selection, or :teleport_target
        @message = nil
        build_desc_window
        build_skill_window
      end

      def dispose
        close_message
        @desc_window.dispose if @desc_window
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

      # Holding a direction auto-repeats the cursor after the initial delay,
      # not just a single step per tap -- see Scene::ItemMenu#update_items's
      # identical comment (`Window_Selectable::Update`, `src/
      # window_selectable.cpp`, and docs/TODO.md for the fuller writeup);
      # every check below just gains an `|| #repeat?` alongside it.
      def update_skills
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_skill_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_skill_cursor(-COLUMN_MAX)
        # Right/Left cross a row boundary rather than stopping at the row's
        # own edge -- see Scene::ItemMenu#update_items's identical comment
        # (confirmed directly against `Window_Selectable::Update`,
        # `src/window_selectable.cpp`: Right/Left are a flat `index +- 1`
        # bounded only by the list's own absolute start/end, no row-boundary
        # check, unlike Down/Up's genuine column-lock).
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_skill_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_skill_cursor(-1)
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
        play_system_se(SFX_CURSOR)
      end

      def choose_skill
        if skills.empty?
          play_system_se(SFX_BUZZER)
          return
        end
        sid, = skills[@skill_index]
        sk = @state.party.db_skill(sid)
        # A greyed-out (currently unusable) entry is selectable but not
        # activatable -- EasyRPG's `Scene_Skill::vUpdate` (`src/scene_skill.cpp`)
        # gates its whole Decision branch on `Window_Skill::CheckEnable`
        # (`IsSkillLearned && IsSkillUsable`, `src/window_skill.cpp`) before
        # playing any SE or pushing `Scene_ActorTarget`/dispatching a
        # switch skill at all; the `else` (disabled) branch just buzzes and
        # stays on the list. `#skills` (`Game::Party#field_skills`) already
        # filters the listing by `#field_skill?` -- the same per-type
        # availability `Algo::IsSkillUsable` covers on the reference's own
        # `IsSkillUsable` -- so `Game::Party#can_cast?` (affordability, the
        # 封印/Silence seal, weapon-Attribute gating) is everything left to
        # check here, the same predicate `Game_Battler::IsSkillUsable`'s own
        # pre-`Algo::IsSkillUsable` checks cover. Previously nothing gated
        # this at all: choosing an unaffordable or sealed skill still played
        # Decision and opened the full target-confirm screen (or, for a
        # switch skill, cast it outright), with the failure only ever
        # surfacing afterward as #apply_skill's "It had no effect." message.
        if @state.party.respond_to?(:can_cast?) && !@state.party.can_cast?(caster, sid)
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        # A switch skill has no target at all; Escape warps straight to its one
        # registered target; Teleport opens a list of every registered target;
        # a self (2), all-ally (4) or single-ally (3) skill all open the same
        # target-confirm screen -- see #enter_target_confirm's own doc comment
        # for why self/all-ally still need one, cursor locked to who it will
        # land on rather than skipped outright.
        if sk && sk.type == Game::Party::SKILL_SWITCH
          apply_switch_skill(sid)
        elsif sk && sk.type == Game::Party::SKILL_ESCAPE
          apply_escape_skill(sid)
        elsif sk && sk.type == Game::Party::SKILL_TELEPORT
          @pending_skill = sid
          @mode = :teleport_target
          @teleport_index = 0
          build_teleport_window
          refresh_desc
        else
          @pending_skill = sid
          enter_target_confirm(sk && sk.scope == 2 ? :self : sk && sk.scope == 4 ? :party : nil)
        end
      end

      # Open the target-confirm screen (`@mode = :target`), locking the
      # cursor when `lock` names who the effect already, unavoidably, lands
      # on: `:self` to the caster's own row, `:party` to the whole list.
      # Real RPG_RT's `Scene_ActorTarget`/`Window_ActorTarget` do the same --
      # `Window_Selectable::Update`'s entire cursor-movement block is gated
      # on `index >= 0` (`src/window_selectable.cpp`), and a self/all-ally
      # skill starts that index negative (`Window_ActorTarget`'s
      # `SetIndex(-actor_index-1)` / `SetIndex(-100)`,
      # `src/scene_actortarget.cpp`) precisely so UP/DOWN never takes effect
      # -- Decision (cast) and Cancel (back out) are the only inputs that do
      # anything, but the screen, and its cancel opportunity, is never
      # skipped. `#apply_skill`'s own `target` argument is irrelevant either
      # way for scope 2/4 (`Game::Party#skill_targets` resolves `[caster]`/
      # `@actors` regardless of what is passed), so locking is purely a UI
      # gate, not a targeting change.
      def enter_target_confirm(lock)
        @mode = :target
        @target_lock = lock
        @target_index = lock == :self ? @caster_index : 0
        build_target_window
        refresh_desc
      end

      def update_target
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_target
        elsif !@target_lock && (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN))
          @target_index += 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif !@target_lock && (Input.trigger?(Input::UP) || Input.repeat?(Input::UP))
          @target_index -= 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          apply_skill(@pending_skill, party[@target_index])
        end
      end

      # A cast that changed nothing plays Buzzer rather than a second
      # Decision -- see Scene::ItemMenu#apply_item's identical reasoning. A
      # *successful* cast stays on this same target screen too, exactly like
      # a no-effect one -- confirmed against RPG_RT's own live source:
      # `Scene_ActorTarget::UpdateSkill` (`src/scene_actortarget.cpp`) never
      # calls `Scene::Pop()` on Decision, success or failure alike; the only
      # `Scene::Pop()` in the whole file is `vUpdate`'s own Cancel branch.
      # `#cast_skill`'s own affordability gate already answers what happens
      # on a repeat cast once SP runs out (an empty `affected`, the same
      # Buzzer path), matching the reference's own SP/HP check ahead of
      # `UseSkill` -- unaffordable buzzes, it does not auto-exit either.
      # Unlike #apply_switch_skill just below, this one is never tagged
      # `:cast` -- it has nowhere to "return to" until Cancel, so
      # `#drive_message` has nothing extra to do once the message closes.
      def apply_skill(sid, target)
        affected = @state.party.cast_skill(caster, sid, target)
        if affected.empty?
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        else
          show_message("#{caster.name} casts #{skill_name(sid)}!")
        end
      end

      # A switch skill (type 3) spends its SP and turns on a game switch, with
      # nothing to target. This is how a Nepheshel player summons and dismisses a
      # companion — the switch is what its common event watches.
      def apply_switch_skill(sid)
        switch = @state.party.cast_switch_skill(caster, sid)
        if switch
          @state.switches[switch] = true
          play_skill_sound_effect(sid)
          show_message("#{caster.name} casts #{skill_name(sid)}!", :cast)
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # Switch and Escape skills replace the ordinary decision SE with their
      # own database `sound_effect` field (schema.rb field 16) on a
      # successful cast -- confirmed against EasyRPG's `Scene_Skill::Update`,
      # which calls `SePlay(skill->sound_effect)` for exactly these two
      # types. Teleport is the odd one out: it keeps playing the ordinary
      # decision SE instead (see #update_teleport_target), so it does not
      # call this. Mirrors #play_cursor_se in scene/title.rb (the same
      # Array1D/SE struct, read the same way) -- a no-op on a blank/absent
      # filename, or when the field carries no SE at all.
      def play_skill_sound_effect(sid)
        sk = @state.party.db_skill(sid)
        se = sk && sk.sound_effect
        return unless se
        name = se.file
        return if name.nil? || name.empty?
        Audio.se_play name, se.volume, se.pitch
      rescue StandardError => e
        $stderr.puts "[RPG2k] skill SE '#{name}' playback failed: #{e.message}"
      end

      # Back to the skill list, rebuilt so it reflects whatever changed while
      # target mode was open (SP fell; a now-unaffordable skill drops out) --
      # only reached via Cancel now that a successful cast no longer forces
      # this on its own (see #apply_skill). Keeps the cursor in range if the
      # list shrank.
      def leave_target
        @pending_skill = nil
        @target_lock = nil
        @mode = :skills
        if @target_window
          @target_window.dispose
          @target_window = nil
        end
        @skills = nil
        @skill_index = skills.size - 1 if @skill_index >= skills.size
        @skill_index = 0 if @skill_index < 0
        build_skill_window
        refresh_desc
      end

      # The destination list is a two-column grid too, not a single stacked
      # column -- confirmed against genuine RPG_RT's own live source:
      # `Window_Teleport` (`src/window_teleport.cpp`) sets `column_max = 2`
      # (`Window_Selectable`'s `wrap_limit` default is also 2, the exact
      # threshold `Window_Selectable::Update`'s RIGHT/LEFT handling gates on),
      # the identical shape this class's own skill list already ports (see
      # `COLUMN_MAX`'s comment). With exactly two destinations, DOWN/UP are
      # no-ops (nothing in the row below/above) and RIGHT reaches the second
      # one -- not DOWN, which this scene wrongly wired to a single-column
      # modulo wrap with no RIGHT/LEFT handling at all.
      def update_teleport_target
        targets = teleport_targets
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_teleport_target
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_teleport_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_teleport_cursor(-COLUMN_MAX)
        # Right/Left cross a row boundary rather than stopping at the row's
        # own edge -- the same fix as #update_skills's identical RIGHT/LEFT
        # handling (confirmed directly against `Window_Selectable::Update`,
        # `src/window_selectable.cpp`: Right/Left are a flat `index +- 1`
        # bounded only by the list's own absolute start/end, no
        # row-boundary check), never propagated to this sibling list when
        # that one was corrected.
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_teleport_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_teleport_cursor(-1)
        elsif Input.trigger?(Input::C) && !targets.empty?
          play_system_se(SFX_DECISION)
          map_id, = targets[@teleport_index]
          apply_teleport_skill(@pending_skill, map_id)
        end
      end

      # Move the teleport-target cursor by `delta` grid cells, ignored if that
      # cell is off the grid -- mirrors #move_skill_cursor exactly (see its
      # own comment).
      def move_teleport_cursor(delta)
        targets = teleport_targets
        return if targets.empty?
        target = @teleport_index + delta
        return if target < 0 || target >= targets.size
        @teleport_index = target
        refresh_teleport_cursor
        play_system_se(SFX_CURSOR)
      end

      # Escape (type 1) warps to the single registered escape target with no
      # picker (see the class comment). A successful cast closes the whole menu
      # stack at once, matching RPG_RT: there is no field-menu message shown
      # afterwards, since the map that would show it is gone before the next
      # frame draws.
      def apply_escape_skill(sid)
        target = @state.party.cast_escape_skill(caster, sid, @state)
        if target
          play_skill_sound_effect(sid)
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
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
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # Queue the warp for Scene::Map (see Game::State#pending_teleport) and pop
      # every menu on top of it in one step. A registered target's own switch
      # (Set Teleport Target / Set Escape Target's optional flag) turns on the
      # instant the warp is queued, matching real RPG_RT's own
      # `Game_Player::ReserveTeleport(const SaveTarget&)` -- see
      # Game::Party#cast_escape_skill/#cast_teleport_skill.
      def queue_teleport(target)
        @state.switches[target[:switch_id]] = true if target[:switch_id]
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
        refresh_desc
      end

      # After a successful cast, drop back to the skill list and rebuild it (SP
      # fell; a now-unaffordable skill drops out).
      # Column width for the skill grid (see Scene::ItemMenu#item_col_w,
      # which this mirrors).
      def skill_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      # The highlighted skill's flavour text, in a one-line banner across the
      # very top of the screen -- see Scene::ItemMenu#build_desc_window,
      # which this mirrors exactly (the same gap, in the Skill screen
      # instead). Tracks the skill under the cursor in :skills mode; the
      # :target/:teleport_target pickers keep showing the pending skill's own
      # description, since it is still the one thing on screen a description
      # could be about.
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
        sid = if @mode == :skills
                rows = skills
                rows.empty? ? nil : rows[@skill_index].first
              else
                @pending_skill
              end
        sk = sid ? @state.party.db_skill(sid) : nil
        text = sk ? sk.description.to_s : ''
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      def build_skill_window
        @skill_window.dispose if @skill_window
        rows = skills
        inner_w = SCREEN_W - Window::BORDER * 2
        head_h = LINE_H
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = head_h + grid_rows * LINE_H
        @skill_window = Window.new(0, DESC_H, SCREEN_W, h + Window::BORDER * 2)
        @skill_window.z = 400
        @skill_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        a = caster
        mp_term = term(:mp_short, 'MP')
        c.draw_text 0, 0, inner_w, LINE_H, "#{a.name}   #{mp_term} #{a.mp}/#{a.display_max_mp}"
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
        refresh_desc
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
                      "#{term(:hp_short, 'HP')} #{a.hp}/#{a.display_max_hp}  " \
                      "#{term(:mp_short, 'MP')} #{a.mp}/#{a.display_max_mp}"
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      def refresh_target_cursor
        return unless @target_window
        # A :party lock (an all-ally skill) highlights every row at once --
        # EasyRPG's own Window_ActorTarget::UpdateCursorRect draws exactly
        # this for its `index < -10` ("Entire Party") case -- rather than
        # the single-row rect a :self lock or an ordinary single-ally pick
        # uses.
        if @target_lock == :party
          @target_window.cursor_rect =
            Rect.new(0, 0, @target_window.contents.width, @target_window.contents.height)
        else
          @target_window.cursor_rect =
            Rect.new(0, @target_index * LINE_H * 2, @target_window.contents.width,
                     LINE_H * 2)
        end
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

      # Column width for the teleport-destination grid (see #update_teleport_target's
      # grid comment above; identical formula to #skill_col_w).
      def teleport_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      def build_teleport_window
        @teleport_window.dispose if @teleport_window
        rows = teleport_targets
        inner_w = SCREEN_W - Window::BORDER * 2
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = grid_rows * LINE_H
        @teleport_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                      SCREEN_W, h + Window::BORDER * 2)
        @teleport_window.z = 450
        @teleport_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 0, inner_w, LINE_H, "No destinations"
        else
          col_w = teleport_col_w
          rows.each_with_index do |(_id, name), i|
            x = (i % COLUMN_MAX) * col_w
            y = (i / COLUMN_MAX) * LINE_H
            c.draw_text x, y, col_w, LINE_H, name
          end
        end
        @teleport_window.contents = c
        refresh_teleport_cursor
      end

      def refresh_teleport_cursor
        return unless @teleport_window
        h = teleport_targets.empty? ? 0 : LINE_H
        x = (@teleport_index % COLUMN_MAX) * teleport_col_w
        y = (@teleport_index / COLUMN_MAX) * LINE_H
        @teleport_window.cursor_rect = Rect.new(x, y, teleport_col_w, h)
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        # `:cast` only ever tags #apply_switch_skill's message now (see
        # #apply_skill's own comment) -- a switch skill is cast straight from
        # the skill list, with no target screen to stay open on, so its own
        # successful-cast message closes back into a rebuilt list, matching
        # this same class's pre-existing #leave_target/#leave_teleport_target
        # shape for "returning to the list."
        done = @message[:done]
        close_message
        leave_target if done == :cast
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
