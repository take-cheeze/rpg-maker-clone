class RPG2k
  module Scene
    # The field skill screen (main menu -> Skill). Lists every skill one party
    # member knows, in a two-column grid with each row's SP cost, under a
    # description banner and a one-line caster status window -- the three
    # windows, the grid geometry, the cost/status text formats, the scrolling
    # and the "every known skill listed, the field-unusable ones greyed"
    # rule were all measured against genuine RPG_RT.exe under wine (cycle
    # #241, 2026-09-06; see each constant's own comment and docs/TODO.md).
    # Casting a single-ally skill (scope 3) asks who to use it on, while a
    # self (2) or all-ally (4) skill applies at once, spending SP and
    # restoring HP/SP. An Escape skill warps straight to the registered
    # escape target with no prompt; a Teleport skill opens a third list of
    # every registered destination (by map name) to choose from. Either warp
    # closes the whole menu stack and queues the jump for Scene::Map to
    # perform (see Game::State#pending_teleport) rather than applying
    # anything here. All the decision logic is on Game::Party (field_skills /
    # field_skill? / skill_cost / can_cast? / skill_effect / cast_skill /
    # cast_escape_skill / cast_teleport_skill), host-tested; this is the RGSS
    # UI over it.
    #
    # There is no way to switch caster once this screen is open: real RPG_RT
    # hands input focus to the *menu's own party list* when Skill is selected
    # there, letting the player pick which actor first (confirmed live under
    # wine: 特殊技能 on the field menu moves the cursor onto the party panel,
    # and only Return there opens this screen), and this screen then shows
    # that one actor with LEFT/RIGHT free for grid navigation --
    # `Scene::Menu#enter_actor_selection` implements the picker and passes
    # the chosen actor's index in here as the third constructor argument
    # (default 0, the leader, for callers that never had a picker to begin
    # with, e.g. the host test harnesses).
    class SkillMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # The :skills-mode screen is THREE stacked full-width windows, every
      # rect measured off genuine RPG_RT.exe frames under wine (cycle #241,
      # 2026-09-06; 640x480 captures halved -- the skin's white outer border
      # rows sat at 2x y 0/58, 64/122, 128/474, its columns at 2x x 0/634):
      #   description banner  (0,  0, 320, 32)
      #   caster status line  (0, 32, 320, 32)  -- see #build_status_window
      #   skill grid          (0, 64, 320, 176) -- down to the screen's very
      #                                           bottom edge, whatever the
      #                                           skill count (empty included)
      # This scene used to fold the caster's name/MP into a header row of a
      # content-sized grid box and leave the lower screen bare.
      DESC_H = LINE_H + Window::BORDER * 2
      STATUS_H = LINE_H + Window::BORDER * 2
      LIST_Y = DESC_H + STATUS_H
      LIST_H = SCREEN_H - LIST_Y
      # Rows the grid box can show at once (10); a longer list scrolls -- see
      # #refresh_skill_cursor.
      VISIBLE_ROWS = (LIST_H - Window::BORDER * 2) / LINE_H

      # The skill list is a two-column grid filled row-major. Measured on the
      # same cycle-#241 captures (a 26-skill leader): the second column's
      # names start at logical x 168 = contents 160, the first's at contents
      # 0, so the column pitch is `SCREEN_W / 2` = 160 -- NOT the
      # `(inner width) / 2` = 152 Scene::ItemMenu's sibling grid still uses
      # (left as a lead there, unmeasured on that screen). Each row is 16px.
      COLUMN_MAX = 2
      COL_PITCH = SCREEN_W / COLUMN_MAX
      # The highlighted cell's own cursor frame spans logical x 4..155 (152
      # wide) in the first column and 164..315 in the second -- i.e. a
      # `cursor_rect` 144 wide at contents x 0 / 160 once RPG2k::Window's
      # own 4px overhang each side (Game::WindowCursor::OVERHANG) is
      # accounted for. Same 152px frame on an empty list's first cell.
      CELL_CURSOR_W = COL_PITCH - Game::WindowCursor::OVERHANG * 4
      # A row's SP cost is `-%3d` (a hyphen separator, then the cost right-
      # aligned in a three-character field; "-  4", "- 30", "-120" -- no
      # unit) with its right edge at contents x 144 of the cell: the "-"
      # glyph sat at logical 128..130 / 288..290 and the last digit ended at
      # 151 / 311 (exclusive 152 / 312) in the two columns.
      COST_RIGHT = 144

      # Status-line columns (contents x): the caster's name at 0, the
      # database's LV term at 80 in system colour 1 with the level right-
      # aligned in a 2-character field ending at 104 ("LV50" / "LV 5"), the
      # condition at 124, the HP term at 184 (colour 1) with `%3d/%3d` from
      # 196 ("600/600", " 56/ 60"), the MP term at 250 with `%3d/%3d` from
      # 262 ending flush at the 304px inner right edge ("  5/ 60"). Glyph
      # runs at 2x: name 20..82, LV 176..196, level 200..222 (50) / 212..222
      # (5), 正常 264..304, HP 384..400, 408..491 (600/600) / 420..490
      # (" 56/ 60"), MP 516..532, 540..623 / 564..622 ("  5/ 60"). Only the
      # current MP figure recoloured (critical yellow at 5/60), never a label.
      STATUS_LEVEL_X = 80
      STATUS_LEVEL_VALUE_X = 92
      STATUS_STATE_X = 124
      STATUS_HP_X = 184
      STATUS_HP_VALUE_X = 196
      STATUS_MP_X = 250
      STATUS_MP_VALUE_X = 262
      # One `%3d/%3d` pair: a 3-cell (18px) right-aligned current value, a
      # 6px "/" cell, then a 3-cell right-aligned maximum -- 42px in all.
      STAT_FIELD_W = 18
      STAT_SLASH_W = 6
      STAT_PAIR_W = STAT_FIELD_W * 2 + STAT_SLASH_W
      # The level's own 2-cell field.
      LEVEL_FIELD_W = 12

      # Scroll arrows (see #build_arrow_sprites): the same windowskin cells
      # Window's own pause arrow and Scene::SaveLoad's slot list use, blinking
      # 20 frames on / 20 off -- a period no longer merely inherited from the
      # pause arrow, but timed on a list of this exact shape under wine in
      # cycle #249 (0.6667s mean on-to-on over 17 cycles at 60fps; see
      # Scene::Base's own LIST_ARROW_* comment). Measured on the cycle-#241
      # scroll captures, and re-confirmed in #249: the down arrow's
      # triangle spans logical (155..164, 233..238) -- centred, at the
      # screen's bottom edge, exactly where a `SCREEN_H - ARROW_H` blit of
      # the 16x8 cell (whose triangle fills rows 1..6) lands it; the up
      # arrow's spans (155..164, 64..69), flush with the grid box's own top
      # edge, which is where a blit at `LIST_Y` of the up cell lands it --
      # that cell's triangle fills rows 0..5, checked by capturing this
      # engine's own Scene::SaveLoad up arrow (sprite y 32, triangle rows 32..37)
      # drawn from the same Nepheshel skin.
      ARROW_W = Window::ARROW_W
      ARROW_H = Window::ARROW_H
      ARROW_SRC_X = Window::ARROW_SRC_X
      UP_ARROW_SRC_Y = 8
      DOWN_ARROW_SRC_Y = Window::ARROW_SRC_Y
      ARROW_BLINK_FRAMES = Window::ARROW_BLINK_FRAMES
      UP_ARROW_Y = LIST_Y
      DOWN_ARROW_Y = SCREEN_H - ARROW_H

      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @caster_index = actor_index
        @skill_index = 0
        @top_row = 0
        @arrow_anim = 0
        @target_index = 0
        @target_lock = nil
        @teleport_index = 0
        @pending_skill = nil
        @mode = :skills          # :skills list, :target selection, or :teleport_target
        build_desc_window
        build_status_window
        build_skill_window
        build_arrow_sprites
      end

      def dispose
        @desc_window.dispose if @desc_window
        @status_window.dispose if @status_window
        @skill_window.dispose if @skill_window
        @target_window.dispose if @target_window
        @teleport_window.dispose if @teleport_window
        @up_arrow.dispose if @up_arrow
        @down_arrow.dispose if @down_arrow
      end

      def update
        # Every live window needs its own #update called every frame to
        # advance its selection-cursor blink (RPG2k::Window#update) -- this
        # scene never called it at all, the same gap Scene::Menu's own
        # #update had (see its own citation).
        @desc_window.update if @desc_window
        @status_window.update if @status_window
        @skill_window.update if @skill_window
        @target_window.update if @target_window
        @teleport_window.update if @teleport_window
        tick_arrows
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
      # identical comment (ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine, and docs/TODO.md for the fuller writeup);
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
        # (ported from a reference implementation, not independently
        # confirmed against genuine RPG_RT under wine:
        # Right/Left are a flat `index +- 1`
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

      # Whether `sid` (row `sk`, already looked up) cannot currently be cast --
      # shared by #choose_skill's buzz-and-stay gate and #build_skill_window's
      # row colour (see its own comment): field usability itself
      # (`Game::Party#field_skill?` -- an enemy-scope attack, a stat/attribute
      # buff, a cure for battle-only states, a switch skill flagged battle-
      # only; every one of those is *listed* but greyed on genuine RPG_RT,
      # see `#field_skills`' own cycle-#241 write-up), affordability/seal/
      # weapon-Attribute (`Game::Party#can_cast?`) for an ordinary skill, or
      # a missing registered target for Escape/Teleport. Extracted so both
      # call sites agree by construction rather than by two separately-
      # maintained copies of the same check.
      def skill_unavailable?(sid, sk)
        (sk && @state.party.respond_to?(:field_skill?) && !@state.party.field_skill?(sk, @state)) ||
          (@state.party.respond_to?(:can_cast?) && !@state.party.can_cast?(caster, sid)) ||
          (sk && sk.type == Game::Party::SKILL_ESCAPE &&
           @state.party.respond_to?(:escape_skill_available?) &&
           !@state.party.escape_skill_available?(@state)) ||
          (sk && sk.type == Game::Party::SKILL_TELEPORT &&
           @state.party.respond_to?(:teleport_skill_available?) &&
           !@state.party.teleport_skill_available?(@state))
      end

      def choose_skill
        if skills.empty?
          play_system_se(SFX_BUZZER)
          return
        end
        sid, = skills[@skill_index]
        sk = @state.party.db_skill(sid)
        # A greyed-out (currently unusable) entry is selectable but not
        # activatable -- ported from a reference implementation, NOT
        # independently confirmed against genuine RPG_RT under wine: its
        # own skill-scene update gates its whole Decision branch on the
        # skill window's own enable check (learned and usable) before
        # playing any SE or pushing the actor-target scene/dispatching a
        # switch skill at all; the disabled branch just buzzes and stays on
        # the list. `#skills` (`Game::Party#field_skills`) now lists a
        # known skill unconditionally -- matching that reference
        # implementation's own include check, trivially `true` outside
        # battle with no per-type filter at all, a fact this comment
        # previously got backwards (claiming `#field_skill?` already
        # covered per-type availability the way the usable/enable checks
        # actually do) -- so every one of those usability checks needs
        # covering here: `Game::Party#can_cast?` (affordability, the
        # 封印/Silence seal, weapon-Attribute gating -- that reference
        # implementation's own pre-algorithm checks) plus, for the two
        # types its battle algorithm special-cases,
        # `#escape_skill_available?`/`#teleport_skill_available?` (access,
        # a registered target, not flying).
        if skill_unavailable?(sid, sk)
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
          enter_teleport_target
        else
          @pending_skill = sid
          enter_target_confirm(sk && sk.scope == 2 ? :self : sk && sk.scope == 4 ? :party : nil)
        end
      end

      # Open the target-confirm screen (`@mode = :target`), locking the
      # cursor when `lock` names who the effect already, unavoidably, lands
      # on: `:self` to the caster's own row, `:party` to the whole list.
      # Ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: its own actor-target screen does
      # the same --
      # its own cursor-movement block is gated
      # on the index being non-negative, and a self/all-ally
      # skill starts that index negative
      # precisely so UP/DOWN never takes effect
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
        # The description banner and skill-list box both narrow/change content
        # for :target mode -- see #left_panel_w and #build_mp_cost_window.
        # Both rebuild their own content (including a #refresh_desc call), so
        # this needs no separate refresh_desc of its own. The status line goes
        # away outright (#build_status_window disposes it in this mode) and
        # the scroll arrows hide with the grid (#refresh_arrows).
        build_desc_window
        build_status_window
        build_skill_window
        refresh_arrows
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
          apply_skill(@pending_skill, party[@target_index])
        end
      end

      # A cast that changed nothing plays Buzzer rather than the skill's own
      # animation SE -- see Scene::ItemMenu#apply_item's identical reasoning.
      # A *successful* cast stays on this same target screen too, exactly
      # like a no-effect one -- ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine:
      # its own actor-target skill-update never
      # pops the scene on Decision, success or failure alike; the only
      # scene-pop in the whole handler is its own Cancel branch.
      # `#cast_skill`'s own affordability gate already answers what happens
      # on a repeat cast once SP runs out (an empty `affected`, the same
      # Buzzer path), matching the reference's own SP/HP check ahead of
      # its own skill-use -- unaffordable buzzes, it does not auto-exit either.
      #
      # No confirmation message either way -- its own success/
      # failure branches only ever play a sound effect and refresh, playing the
      # skill's own `animation_id`-derived SE (`#play_animation_se`) on
      # success, never building a message window; this class used to show
      # "X casts Y!"/"It had no effect." here (and `#update_target` played a
      # Decision-click SE ahead of every cast, matching neither branch), a
      # fabricated dialog this runtime invented that also forced an extra
      # dismiss press before the next target could be picked.
      def apply_skill(sid, target)
        affected = @state.party.cast_skill(caster, sid, target)
        if affected.empty?
          play_system_se(SFX_BUZZER)
        else
          sk = @state.party.db_skill(sid)
          play_animation_se(sk && sk.animation_id)
        end
      end

      # A switch skill (type 3) spends its SP and turns on a game switch, with
      # nothing to target. This is how a Nepheshel player summons and dismisses a
      # companion — the switch is what its common event watches.
      # A successful cast closes the whole menu stack at once, exactly like
      # Scene::ItemMenu#apply_switch_item and this same class's own
      # #apply_escape_skill just below -- ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine: its own switch-skill update
      # plays the skill's own sound effect and calls
      # pop-until-map on the very same Decision press, with
      # no confirmation message at all -- the identical shape as the
      # escape case right below it, not the ordinary target-mode cast's
      # stay-open-and-show-a-message flow (which
      # pushes an actor-target scene instead). The failure branch
      # is unreachable through ordinary play -- `#choose_skill` already
      # buzzes-and-returns on an uncastable skill before ever calling this
      # (see `#apply_skill`'s own citation for the same not-independently-
      # confirmed reasoning that a no-effect Decision never shows a message) -- but
      # it is kept message-free for consistency with every reachable sibling.
      def apply_switch_skill(sid)
        switch = @state.party.cast_switch_skill(caster, sid)
        if switch
          @state.switches[switch] = true
          play_skill_sound_effect(sid)
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # Switch and Escape skills replace the ordinary decision SE with their
      # own database `sound_effect` field (schema.rb field 16) on a
      # successful cast -- matching a reference implementation's own
      # skill-scene update, which plays that field's SE for exactly these
      # two types. Teleport is the odd one out: it keeps playing the ordinary
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
        Audio.se_play name, se.volume, se.pitch, se.balance
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
        # The status line comes back too, refreshed -- confirmed against
        # genuine RPG_RT.exe under wine (cycle #241): after casting マーフェ
        # (4 MP) from 5 MP on the target screen and cancelling out, the
        # list's status line read "MP   1/ 60" and every now-unaffordable
        # row (マーフェ itself included) had turned to the disabled colour,
        # cursor still on the same cell.
        build_status_window
        build_skill_window
        # Back to full width now that :target mode's own narrowed banner is
        # gone -- see #left_panel_w. Rebuilds rather than a plain
        # #refresh_desc so the width actually changes back, not just the text.
        build_desc_window
        refresh_arrows
      end

      # The destination list is a two-column grid too, not a single stacked
      # column -- the identical shape this class's own skill list already
      # ports (see `COLUMN_MAX`'s comment, confirmed against genuine RPG_RT
      # under wine for the sibling Item list), carried over on the strength
      # of that shared shape rather than separately re-measured. With
      # exactly two destinations, DOWN/UP are
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
        # handling (ported from a reference implementation, not
        # independently confirmed against genuine RPG_RT under wine:
        # Right/Left are a flat `index +- 1`
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
      # frame draws. Failure is unreachable the same way #apply_switch_skill's
      # is (`#escape_skill_available?` gates `#choose_skill` first).
      def apply_escape_skill(sid)
        target = @state.party.cast_escape_skill(caster, sid, @state)
        if target
          play_skill_sound_effect(sid)
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # Teleport (type 2), once a destination is chosen from the list built by
      # #build_teleport_window. Failure is unreachable the same way
      # (`#teleport_skill_available?` gates `#choose_skill` first).
      def apply_teleport_skill(sid, map_id)
        target = @state.party.cast_teleport_skill(caster, sid, @state, map_id)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # Queue the warp for Scene::Map (see Game::State#pending_teleport) and pop
      # every menu on top of it in one step. A registered target's own switch
      # (Set Teleport Target / Set Escape Target's optional flag) turns on the
      # instant the warp is queued, ported from a reference implementation's
      # own teleport-target reservation, not independently confirmed
      # against genuine RPG_RT under wine -- see
      # Game::Party#cast_escape_skill/#cast_teleport_skill.
      def queue_teleport(target)
        @state.switches[target[:switch_id]] = true if target[:switch_id]
        @state.pending_teleport = [target[:map_id], target[:x], target[:y], 0]
        @parent.pop_to_map
      end

      # :teleport_target's own left side -- unlike :target mode (which
      # narrows the description banner/skill grid to make room for a
      # right-anchored panel, cycles #140/#141), the destination picker
      # removes both entirely, leaving raw map background where they used
      # to be -- confirmed against genuine RPG_RT.exe under wine (cycle
      # #142, closing the lead cycles #140/#141 both explicitly left open):
      # driving a synthetic Teleport-type skill (Set Teleport Target /
      # Change Teleport Access have no existing exerciser in Nepheshel's own
      # database, so this needed a scratch skill row and a hand-edited save
      # -- see docs/TODO.md's own cycle #142 entry for the full recipe) into
      # this screen showed a solid map-coloured band across the whole top
      # two-thirds of the screen, with no window border/gradient anywhere in
      # it, directly above the destination list's own full-width, bottom-
      # anchored box -- not the banner/grid merely covered (the destination
      # box does not span that height) nor narrowed (its own box runs the
      # full `SCREEN_W`, not `SCREEN_W - TARGET_W`). Tested at both ends of
      # the registered-destination-count boundary this cycle could reach (1
      # and 3 targets); both left the same bare band above the list.
      # Cancelling out (confirmed live, both counts) restores the ordinary
      # full-width :skills banner and grid exactly, which #leave_teleport_
      # target's own rebuild (mirroring #enter_teleport_target) now matches.
      def enter_teleport_target
        if @desc_window
          @desc_window.dispose
          @desc_window = nil
        end
        if @status_window
          @status_window.dispose
          @status_window = nil
        end
        if @skill_window
          @skill_window.dispose
          @skill_window = nil
        end
        refresh_arrows
        build_teleport_window
      end

      def leave_teleport_target
        @pending_skill = nil
        @mode = :skills
        if @teleport_window
          @teleport_window.dispose
          @teleport_window = nil
        end
        build_desc_window
        build_status_window
        build_skill_window
        refresh_arrows
      end

      # The description banner and the skill-list box below it both run the
      # full screen width in :skills mode, but narrow to leave room for the
      # right-anchored target panel once :target mode is entered -- confirmed
      # against genuine RPG_RT.exe under wine (cycle #141), closing the lead
      # cycle #140 deliberately left open when it fixed this same reflow for
      # Scene::ItemMenu but not here: both boxes sit flush against the target
      # panel's own left edge (`SCREEN_W - TARGET_W`), not the full screen --
      # pixel-sampled at the identical native x (136, the border pattern
      # starting right where the target panel's own left edge does) as the
      # already-fixed Item screen. :teleport_target never reaches this
      # formula at all -- #enter_teleport_target disposes both windows
      # outright rather than narrowing them (cycle #142; see its own doc
      # comment), so `@mode == :teleport_target` never calls #build_desc_
      # window/#build_skill_window in the first place. Left branchless (only
      # :target narrows) rather than adding a dead :teleport_target case.
      def left_panel_w
        @mode == :target ? SCREEN_W - TARGET_W : SCREEN_W
      end

      # The highlighted skill's flavour text, in a one-line banner across the
      # very top of the screen -- see Scene::ItemMenu#build_desc_window,
      # which this mirrors exactly (the same gap, in the Skill screen
      # instead). Tracks the skill under the cursor in :skills mode. Once
      # :target mode narrows this banner (see #left_panel_w), real RPG_RT
      # switches its text too -- confirmed against genuine RPG_RT.exe under
      # wine (cycle #141), the same swap cycle #140 already found on the Item
      # screen: it shows the pending skill's own *name* (e.g. "マーフェ"),
      # not its description, while target mode is open, for a single-ally
      # (scope 3), self-locked (scope 2) and all-ally-locked (scope 4) skill
      # alike -- all three tested, since #enter_target_confirm's own lock
      # argument only changes cursor behaviour, not (as this fix confirms)
      # whether the reflow happens. This method is never reached in
      # :teleport_target mode at all (see #enter_teleport_target, cycle
      # #142) since that mode disposes `@desc_window` outright rather than
      # refreshing its text.
      def build_desc_window
        @desc_window.dispose if @desc_window
        w = left_panel_w
        inner_w = w - Window::BORDER * 2
        @desc_window = Window.new(0, 0, w, DESC_H)
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
        text = if sk.nil?
                 ''
               elsif @mode == :target
                 sk.name.to_s
               else
                 sk.description.to_s
               end
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      # The caster's one-line status window between the banner and the grid
      # (:skills mode only -- :target mode puts the "MP cost" box in its
      # place, see #build_mp_cost_window, and :teleport_target removes it
      # along with everything else, see #enter_teleport_target). Measured
      # against genuine RPG_RT.exe under wine (cycle #241): "デモ用   LV50
      # 正常   HP600/600   MP600/600" on one line, name/values in system
      # colour 0 and the LV/HP/MP terms in colour 1, at the STATUS_* columns
      # documented up top. This screen used to fold a "name   MP cur/max"
      # header into the grid box instead, with no level, condition or HP.
      def build_status_window
        @status_window.dispose if @status_window
        @status_window = nil
        return unless @mode == :skills
        inner_w = SCREEN_W - Window::BORDER * 2
        @status_window = Window.new(0, DESC_H, SCREEN_W, STATUS_H)
        @status_window.z = 400
        @status_window.windowskin = @skin
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        a = caster
        draw_system_text c, 0, 0, STATUS_LEVEL_X, LINE_H, a.name.to_s, @skin
        draw_system_text c, STATUS_LEVEL_X, 0, STATUS_LEVEL_VALUE_X - STATUS_LEVEL_X, LINE_H,
                         term(:level_short), @skin, 1
        draw_system_text c, STATUS_LEVEL_VALUE_X, 0, LEVEL_FIELD_W, LINE_H, a.level.to_s, @skin, 0, 2
        draw_actor_state c, a, STATUS_STATE_X, 0, STATUS_HP_X - STATUS_STATE_X, LINE_H, @skin
        draw_system_text c, STATUS_HP_X, 0, STATUS_HP_VALUE_X - STATUS_HP_X, LINE_H,
                         term(:hp_short), @skin, 1
        draw_stat_pair c, STATUS_HP_VALUE_X, 0, a.hp, a.display_max_hp, true
        draw_system_text c, STATUS_MP_X, 0, STATUS_MP_VALUE_X - STATUS_MP_X, LINE_H,
                         term(:mp_short), @skin, 1
        draw_stat_pair c, STATUS_MP_VALUE_X, 0, a.mp, a.display_max_mp, false
        @status_window.contents = c
      end

      # One `%3d/%3d` current/maximum pair starting at contents `x` (see
      # STAT_FIELD_W): the current value right-aligned in its own 3-cell
      # field, recoloured through Scene::Base#value_font_color exactly as the
      # genuine frame showed (MP 5/60 drew its "5" in the critical colour
      # while "/ 60", the label and every HP figure stayed colour 0), then
      # the "/" and the maximum right-aligned in the last 3 cells. Drawn as
      # three right-/left-aligned pieces at fixed x rather than one padded
      # string, so the layout does not depend on this engine's own space-
      # glyph advance matching RPG_RT's fixed 6px cell.
      def draw_stat_pair(c, x, y, cur, max, can_knockout)
        draw_system_text c, x, y, STAT_FIELD_W, LINE_H, cur.to_s, @skin,
                         value_font_color(cur, max, can_knockout), 2
        draw_system_text c, x + STAT_FIELD_W, y, STAT_SLASH_W, LINE_H, '/', @skin
        draw_system_text c, x + STAT_FIELD_W + STAT_SLASH_W, y, STAT_FIELD_W, LINE_H,
                         max.to_s, @skin, 0, 2
      end

      # The skill grid box in :skills mode; a single-row "MP cost" box in its
      # place once :target mode is entered -- see #build_mp_cost_window.
      def build_skill_window
        @skill_window.dispose if @skill_window
        if @mode == :target
          build_mp_cost_window
          return
        end
        inner_w = SCREEN_W - Window::BORDER * 2
        @skill_window = Window.new(0, LIST_Y, SCREEN_W, LIST_H)
        @skill_window.z = 400
        @skill_window.windowskin = @skin
        @skill_contents = Bitmap.new(inner_w, VISIBLE_ROWS * LINE_H)
        @skill_contents.font.color = Color.new(255, 255, 255, 255)
        @skill_window.contents = @skill_contents
        # #refresh_skill_cursor clamps @top_row for the current cursor row
        # and (re)draws the visible rows through #draw_skill_rows.
        @rows_drawn_from = nil
        refresh_skill_cursor
      end

      # Draw the VISIBLE_ROWS rows from `@top_row` down into the grid box's
      # contents (the whole list never exists as one tall bitmap; the box
      # shows a 10-row window onto it, redrawn whenever @top_row moves).
      #
      # An empty skill list draws no placeholder text -- confirmed against
      # genuine RPG_RT under wine (cycle #241, the leader's chunk-108 skill
      # list empty): a blank grid box with the cursor frame on its first
      # cell (see #refresh_skill_cursor) rather than a message.
      #
      # A row whose skill is not currently castable (not field-usable at all,
      # unaffordable SP, a sealed/missing weapon Attribute, an unregistered
      # Escape/Teleport target -- see #skill_unavailable?) is still drawn, in
      # the windowskin's disabled swatch (index 3) rather than the enabled
      # one (0) -- the same convention Scene::ItemMenu#build_item_window
      # already applies, and confirmed here directly, not just by analogy:
      # a genuine RPG_RT.exe frame (party leader with one affordable and
      # two unaffordable self-scope skills at 2/8/20 SP against 5 current)
      # pixel-sampled the affordable row's glyph at (165,211,255) and an
      # unaffordable row's at (99,166,247) -- the exact same two colours
      # the item-list capture measured for its own usable/unusable rows;
      # cycle #241 re-sampled the same pair on a 26-skill list (enemy-scope,
      # buff, battle-only-cure and unaffordable rows all at (99,166,247)).
      def draw_skill_rows
        c = @skill_contents
        return unless c
        c.clear
        rows = skills
        first = @top_row * COLUMN_MAX
        last = [first + VISIBLE_ROWS * COLUMN_MAX, rows.size].min
        (first...last).each do |i|
          sid, cost = rows[i]
          x = (i % COLUMN_MAX) * COL_PITCH
          y = (i / COLUMN_MAX - @top_row) * LINE_H
          sk = @state.party.db_skill(sid)
          idx = skill_unavailable?(sid, sk) ? 3 : 0
          draw_system_text(c, x, y, COST_RIGHT - 24, LINE_H, skill_name(sid), @skin, idx)
          # `-%3d` right-aligned so its last digit ends at COST_RIGHT (see
          # its own measurement up top) whatever this engine's glyph
          # advances are.
          draw_system_text(c, x, y, COST_RIGHT, LINE_H, "-%3d" % cost, @skin, idx, 2)
        end
        @rows_drawn_from = @top_row
      end

      # The "MP cost" box that replaces the skill grid (and, sitting at the
      # status line's own rect, the status line) once :target mode is
      # entered -- confirmed against
      # genuine RPG_RT.exe under wine (cycle #141): the skill list is not
      # merely covered by the target panel, it is replaced outright by a
      # second, short box directly under the (also-narrowed, see
      # #left_panel_w) description banner -- the same "narrower, split into
      # two stacked boxes" shape cycle #140 already fixed for Scene::ItemMenu,
      # but with the database's own `mp_cost` term ("消費ＭＰ"/"MP Cost")
      # rather than `possessed_items`, since a skill is cast, not consumed
      # from a bag -- resolving the guess cycle #140's own doc comment left
      # open ("plausibly an MP消費/cost box... but genuinely unverified").
      # Measured on a single-ally heal (マーフェ, 4 MP) and re-confirmed on a
      # self-locked heal (再生能力, 20 MP) and an all-ally-locked heal
      # (エレクマーシャ, 30 MP): the box sits at the skill window's own
      # former top-left corner (`(0, DESC_H)`), is exactly `DESC_H` tall (one
      # row) and as wide as the narrowed banner above it, regardless of scope
      # or lock. Its one line is `term(:mp_cost)` flush left and
      # the pending skill's own cost (`Game::Party#skill_cost`, the same value
      # the ordinary grid row already shows) flush right (`align` 2) -- the
      # identical "term left, value right" row shape as
      # Scene::ItemMenu#build_possessed_window and `Scene::Map#draw_shop_
      # status`, a real recurring RPG_RT layout rather than a coincidence of
      # one screen.
      #
      # :teleport_target does not get an MP-cost box of its own at all --
      # confirmed against genuine RPG_RT.exe under wine (cycle #142): unlike
      # :target, the destination picker does not narrow-and-replace the left
      # column, it removes it outright (see #enter_teleport_target's own doc
      # comment).
      def build_mp_cost_window
        w = left_panel_w
        inner_w = w - Window::BORDER * 2
        @skill_window = Window.new(0, DESC_H, w, DESC_H)
        @skill_window.z = 400
        @skill_window.windowskin = @skin
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, LINE_H, term(:mp_cost)
        sk = @pending_skill ? @state.party.db_skill(@pending_skill) : nil
        cost = sk ? @state.party.skill_cost(sk, caster) : 0
        c.draw_text 0, 0, inner_w, LINE_H, cost.to_s, 2
        @skill_window.contents = c
      end

      # Scrolling -- confirmed against genuine RPG_RT.exe under wine (cycle
      # #241, a 26-skill / 13-row leader in the 10-row box): the list never
      # moves while the cursor stays within the visible rows; moving DOWN off
      # the bottom visible row scrolls the list up by exactly one row, the
      # cursor staying on the bottom visible row (rows 2..11 shown with the
      # cursor on row 11 after two such steps, at the same logical y 216),
      # and moving UP off the top visible row scrolls it back one row the
      # same way (top row 3 -> 2 -> 1 across two UPs, cursor pinned at y 72).
      # The blinking down/up arrows show while rows are hidden below/above
      # (see #refresh_arrows). Re-confirmed in cycle #249 on a 26-skill
      # leader: the offset is **sticky**, i.e. `@top_row` is moved by the
      # smallest amount that keeps the cursor's row visible and is otherwise
      # left alone -- ten Downs scrolled the box to top row 1 and an Up from
      # there kept it at 1 (the cursor stepped up inside the box, landing on
      # its ninth visible row), where deriving the offset from the cursor row
      # would have snapped it back to 0.
      def refresh_skill_cursor
        return unless @skill_window
        row = @skill_index / COLUMN_MAX
        @top_row = row if row < @top_row
        @top_row = row - VISIBLE_ROWS + 1 if row >= @top_row + VISIBLE_ROWS
        @top_row = 0 if @top_row < 0
        draw_skill_rows if @rows_drawn_from != @top_row
        # The cursor frame stays on the first cell even with no skills (see
        # #draw_skill_rows). Highlights just the one grid cell, not the full
        # row -- CELL_CURSOR_W wide at the cell's own COL_PITCH column.
        x = (@skill_index % COLUMN_MAX) * COL_PITCH
        y = (row - @top_row) * LINE_H
        @skill_window.cursor_rect = Rect.new(x, y, CELL_CURSOR_W, LINE_H)
        refresh_desc
        refresh_arrows
      end

      # Rows the grid holds in all (an empty list still occupies one row for
      # its cursor).
      def total_rows
        [(skills.size + COLUMN_MAX - 1) / COLUMN_MAX, 1].max
      end

      # Two independent sprites pinned to the grid box's top edge and the
      # screen's bottom edge, centred -- see the ARROW_* constants for the
      # measurement; the same shape Scene::SaveLoad#build_arrow_sprites
      # already draws for its slot list.
      def build_arrow_sprites
        @up_arrow = build_arrow_sprite(UP_ARROW_SRC_Y, UP_ARROW_Y)
        @down_arrow = build_arrow_sprite(DOWN_ARROW_SRC_Y, DOWN_ARROW_Y)
        refresh_arrows
      end

      # Scene::Base's shared list-arrow sprite (the same cells and fallback
      # triangle every other scrolling list here draws), at this screen's own
      # measured column and row.
      def build_arrow_sprite(src_y, y)
        build_list_arrow_sprite(@skin, src_y, (SCREEN_W - ARROW_W) / 2, y)
      end

      # Advance the blink phase every frame and refresh visibility from it
      # (the 20-on/20-off cycle Window's pause arrow uses; see ARROW_*).
      def tick_arrows
        return unless @up_arrow
        @arrow_anim = (@arrow_anim + 1) % (ARROW_BLINK_FRAMES * 2)
        refresh_arrows
      end

      # An arrow shows only in :skills mode (the grid box is gone in the
      # other two), while blinking "on", and while rows are hidden in its
      # direction.
      def refresh_arrows
        return unless @up_arrow
        showing = @mode == :skills && @skill_window && @arrow_anim < ARROW_BLINK_FRAMES
        @up_arrow.visible = !!(showing && @top_row > 0)
        @down_arrow.visible = !!(showing && @top_row + VISIBLE_ROWS < total_rows)
      end

      # See Scene::ItemMenu's identical `TARGET_W`/`TARGET_ROW_H`/
      # `TARGET_ROW_PITCH`/`TARGET_LABEL_X`/`TARGET_VALUE_X` doc comment
      # (cycle #132, extended cycle #137 with the face-drawing geometry and
      # cycle #138 with the real 58px row pitch) for the full RPG_RT
      # measurement write-up -- this class's own target-confirm screen shares
      # the exact same geometry (a genuine RPG_RT.exe under wine draws
      # Scene_Skill's actor-target picker identically to Scene_Item's), so
      # the constants and methods below are ported verbatim from there rather
      # than re-measured independently.
      TARGET_W = 184
      TARGET_ROW_H = LINE_H * 3
      TARGET_ROW_PITCH = 58
      TARGET_LABEL_X = 56
      TARGET_VALUE_X = 114
      TARGET_FACE_X = 8
      TARGET_FACE_SIZE = 48

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = TARGET_W - Window::BORDER * 2
        @target_window = Window.new(SCREEN_W - TARGET_W, 0, TARGET_W, SCREEN_H)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, SCREEN_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        # Row text formats measured on this screen's own genuine RPG_RT.exe
        # frame under wine (cycle #241, the leader at Lv 5 with 56/60 HP and
        # 5/60 MP): the name at contents 56 in colour 0; the LV term at 56 in
        # colour 1 followed by the level right-aligned in a 2-cell field
        # ("LV 5", and "LV50" on the field menu's own panel); the HP/MP terms
        # at 114 in colour 1 followed by `%3d/%3d` from 126 (" 56/ 60",
        # "  5/ 60", the "5" in the critical colour) ending flush at the
        # 168px inner right edge -- the identical shape as the skill screen's
        # own status line (#build_status_window). This used to draw
        # "Lv 5"/"HP 56/60" flat white and unpadded.
        party.each_with_index do |a, i|
          y = i * TARGET_ROW_PITCH
          draw_target_face c, a, y
          draw_system_text c, TARGET_LABEL_X, y, inner_w - TARGET_LABEL_X, LINE_H, a.name.to_s, @skin
          draw_system_text c, TARGET_LABEL_X, y + LINE_H, LEVEL_FIELD_W, LINE_H,
                           term(:level_short), @skin, 1
          draw_system_text c, TARGET_LABEL_X + LEVEL_FIELD_W, y + LINE_H, LEVEL_FIELD_W, LINE_H,
                           a.level.to_s, @skin, 0, 2
          draw_system_text c, TARGET_VALUE_X, y + LINE_H, LEVEL_FIELD_W, LINE_H,
                           term(:hp_short), @skin, 1
          draw_stat_pair c, TARGET_VALUE_X + LEVEL_FIELD_W, y + LINE_H, a.hp, a.display_max_hp, true
          # RPG_RT's target list shows each member's condition -- which is
          # most of the point of the list, since it is where you pick who to
          # use an antidote on ("正常" at 56 on the third line of the frame).
          draw_actor_state c, a, TARGET_LABEL_X, y + LINE_H * 2,
                           TARGET_VALUE_X - TARGET_LABEL_X, LINE_H, @skin
          draw_system_text c, TARGET_VALUE_X, y + LINE_H * 2, LEVEL_FIELD_W, LINE_H,
                           term(:mp_short), @skin, 1
          draw_stat_pair c, TARGET_VALUE_X + LEVEL_FIELD_W, y + LINE_H * 2, a.mp, a.display_max_mp, false
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      # See Scene::ItemMenu#draw_target_face's identical comment/citation.
      def draw_target_face(c, actor, y)
        return unless actor.respond_to?(:faceset_name)
        face = load_face_bitmap(actor.faceset_name)
        return unless face
        index = actor.respond_to?(:faceset_index) ? (actor.faceset_index || 0) : 0
        src = Rect.new((index % 4) * TARGET_FACE_SIZE, (index / 4) * TARGET_FACE_SIZE,
                       TARGET_FACE_SIZE, TARGET_FACE_SIZE)
        c.blt TARGET_FACE_X, y, face, src
      end

      # See Scene::ItemMenu#load_face_bitmap's identical comment.
      def load_face_bitmap(name)
        return nil if name.nil? || name.empty?
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
      end

      def refresh_target_cursor
        return unless @target_window
        # A :party lock (an all-ally skill) highlights every row at once --
        # see Scene::ItemMenu#refresh_target_cursor's identical comment.
        if @target_lock == :party
          @target_window.cursor_rect =
            Rect.new(0, 0, @target_window.contents.width, @target_window.contents.height)
        else
          # The single-row frame spans logical x 196..315 (120 wide) and y
          # 8..55 (48 tall) on this screen's own genuine frame (cycle #241)
          # -- i.e. a `cursor_rect` starting exactly at TARGET_LABEL_X once
          # RPG2k::Window's 4px overhang each side is accounted for, not the
          # `TARGET_LABEL_X - 2` Scene::ItemMenu's port still uses (left as a
          # lead there; unmeasured on that screen this cycle).
          @target_window.cursor_rect =
            Rect.new(TARGET_LABEL_X, @target_index * TARGET_ROW_PITCH,
                     @target_window.contents.width - TARGET_LABEL_X, TARGET_ROW_H)
        end
      end

      # The registered teleport destinations as `[map_id, name]` pairs,
      # ascending by map id — the same order `Game::State#teleport_targets`
      # (a plain hash built by Set Teleport Target) already keeps them in, and
      # the same order a reference implementation lists them in (sorted by
      # map id on insert).
      def teleport_targets
        @state.teleport_targets.keys.sort.map { |id| [id, map_display_name(id)] }
      end

      # A map's editor name for the teleport picker, or its bare id when the
      # tree carries no name for it (a bare fixture, or an id the tree does not
      # know) — matching a reference implementation's own map-name lookup,
      # which reads the same map-tree field this build's #map_properties
      # elsewhere already exposes.
      def map_display_name(map_id)
        row = map_tree.respond_to?(:map_properties) ? map_tree.map_properties[map_id] : nil
        name = row && row.respond_to?(:name) ? row.name.to_s : nil
        name.nil? || name.empty? ? "Map #{map_id}" : name
      end

      # Column width for the teleport-destination grid (see #update_teleport_target's
      # grid comment above; the `(inner width) / 2` Scene::ItemMenu's grids
      # use -- not re-measured on this picker, unlike the skill grid's own
      # COL_PITCH).
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

    end

  end
end
