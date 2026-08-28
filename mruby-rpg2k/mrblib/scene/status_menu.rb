class RPG2k
  module Scene
    # The field status screen (main menu -> Status). Shows one party member's full
    # detail -- name/title, level, EXP and the next level's absolute EXP
    # threshold, HP/MP, the six stats and the five equipment slots; LEFT/
    # RIGHT cycle the member. Read-only, so there is no sub-mode. The "Next"
    # figure is Game::Actor#next_level_exp -- the absolute threshold, matching
    # EasyRPG Player's `Window_ActorStatus::DrawStatus` (`GetNextExpString`)
    # rather than the remaining-EXP delta `#exp_to_next` computes; ported from
    # EasyRPG's source, NOT independently confirmed against genuine RPG_RT
    # under wine (host-tested only); the rest reads existing accessors.
    class StatusMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      # The condition row: which line of the panel it is, its label, and where
      # the state itself starts (clear of the label).
      STATE_ROW = 5
      STATE_LABEL = "State".freeze
      STATE_VALUE_X = 48
      # The HP/MP row: which line of the panel it is. Drawn separately from
      # the flat `lines` pass below (see #draw_hp_mp_row) since, unlike every
      # other line on this screen, its two current-value figures each need
      # their own palette colour.
      HP_MP_ROW = 3

      # `actor_index` is which party member the screen opens on -- the one
      # `Scene::Menu#enter_actor_selection` preselected from the menu's own
      # party list, matching EasyRPG's `Scene_Status` constructor (which
      # takes the same parameter) -- defaulting to 0 (the leader) for
      # callers that never had a picker to begin with, e.g. the host test
      # harnesses. LEFT/RIGHT still cycle from there once inside, the same
      # way EasyRPG's own `Scene_Status::vUpdate` does; ported from EasyRPG's
      # source, NOT independently confirmed against genuine RPG_RT under wine.
      def initialize parent, state, actor_index = 0
        super parent
        @state = state
        @skin = make_windowskin
        @actor_index = actor_index
        @slots = [
          term(:weapon, "Weapon"), term(:shield, "Shield"), term(:armor, "Armor"),
          term(:helmet, "Helmet"), term(:accessory, "Accessory")
        ]
        @warned_missing_item_ids = {}
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
        # A solo party leaves RIGHT/LEFT silent no-ops -- ported from
        # EasyRPG Player's source, NOT independently confirmed against
        # genuine RPG_RT under wine: `Scene_Status::vUpdate`
        # (`src/scene_status.cpp`) gates both branches on `actors.size() >
        # 1`, not just the trigger itself, so a lone hero's Status screen
        # plays no cursor SE and rebuilds nothing on either key.
        elsif party.size > 1 && Input.trigger?(Input::RIGHT)
          @actor_index += 1
          @actor_index %= party.size
          build_window
          play_system_se(SFX_CURSOR)
        elsif party.size > 1 && Input.trigger?(Input::LEFT)
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
        if it.nil?
          warn_missing_item(id)
          return "Item #{id}"
        end
        n = it.name.to_s
        n.empty? ? "Item #{id}" : n
      end

      # #item_name's diagnostic for an equipped slot whose item id has no
      # database row -- the "item" case from docs/TODO.md's runtime error
      # catalog's dangling-id list (a database shrink leaving a stale
      # reference behind), on this screen's equipped-slot *display* path
      # rather than the field/battle Item-menu's inventory-*list*-filtering
      # one (a separate fix). The placeholder label is unchanged; this is
      # diagnostics only. Deduped per id for the scene's lifetime --
      # #item_name reruns every time the window rebuilds (every LEFT/RIGHT
      # actor switch), and logging each of those for an id that never
      # resolves would spam the console for as long as the screen stays
      # open.
      def warn_missing_item(id)
        return if @warned_missing_item_ids[id]
        @warned_missing_item_ids[id] = true
        $stderr.puts "[RPG2k] Status screen: item ##{id} not found in the " \
                     "database, showing a placeholder label"
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
        # The "Next" figure is the *absolute* EXP threshold for the next
        # level, not the remaining delta -- ported from EasyRPG Player's
        # source, NOT independently confirmed against genuine RPG_RT under
        # wine: `Window_ActorStatus::DrawStatus`
        # (`src/window_actorstatus.cpp`) draws the Exp row via
        # `DrawMinMax(90, 34, -1, -1)`, whose `-1, -1` sentinel routes both
        # halves through `actor.GetExpString(true)`/`GetNextExpString(true)`
        # rather than the literal `min`/`max` a normal HP/MP-style call
        # would draw; `Game_Actor::GetNextExpString` (`src/game_actor.cpp`)
        # stringifies `GetNextExp()`, which is `exp_list[GetLevel()]` --
        # the same absolute cumulative-total curve value `CalculateExp`
        # produces, not a subtraction against current EXP. `#next_level_exp`
        # (`mruby-rpg2k/mrblib/game.rb`) already computes exactly this
        # absolute value; `#exp_to_next` instead subtracts current EXP from
        # it, matching neither RPG_RT's own displayed number.
        nxt = a.next_level_exp
        lines = [
          header,
          # RPG_RT always draws a labelled Class/Profession row on this
          # screen too, between Name and Title -- ported from EasyRPG
          # Player's source, NOT independently confirmed against genuine
          # RPG_RT under wine: `Window_ActorInfo::DrawInfo`
          # (`src/window_actorinfo.cpp`):
          # `TextDraw(..., "Class"); DrawActorClass(actor, ...)`, with no
          # version gate around it (unlike the RPG2003-only Row line just
          # above it in the same function), so it draws blank rather than
          # being omitted for an RPG2000 database with no class table.
          # `easyrpg_status_scene_class` has no counterpart in RPG_RT's own
          # Term chunk (an EasyRPG-only extension term), so real RPG_RT
          # hardcodes the English label, matching this codebase's own
          # `order.rb` precedent for "Confirm"/"Redo".
          "Class: #{a.respond_to?(:class_name) ? a.class_name : ''}",
          "#{term(:level_short, 'Lv')} #{a.level}    " \
          "#{term(:exp_short, 'EXP')} #{a.exp}    Next #{nxt.nil? ? '---' : nxt}",
          # Drawn separately, after this flat pass -- see #draw_hp_mp_row.
          '',
          # ATK/DEF/Int(Spirit)/AGI, state-adjusted -- ported from EasyRPG
          # Player's source, NOT independently confirmed against genuine
          # RPG_RT under wine: `Window_ParamStatus::Refresh`
          # (`src/window_paramstatus.cpp`) draws `actor.GetAtk()`/`GetDef()`/
          # `GetSpi()`/`GetAgi()` directly, and `Game_Battler::GetAtk` et al.
          # (`src/game_battler.cpp`) run the base value through `AdjustParam`,
          # which halves/doubles it against whatever states the actor
          # currently carries (`GetInflictedStates()`, not battle-scoped) --
          # so a halving/doubling state that persists onto the map shows its
          # effect here too, not just in battle math. `Game::Party
          # #effective_atk`/`#effective_def`/`#effective_int`/`#effective_agi`
          # already port this (built for skill formulas, see their own
          # citation) but were never wired into this screen.
          "#{term(:attack, 'Atk')} #{@state.party.effective_atk(a)}   " \
          "#{term(:defense, 'Def')} #{@state.party.effective_def(a)}   " \
          "#{term(:mind, 'Int')} #{@state.party.effective_int(a)}   " \
          "#{term(:agility, 'Agi')} #{@state.party.effective_agi(a)}",
          # The condition gets a labelled row of its own, as on RPG_RT's status
          # screen (its Window_ActorInfo draws the label then the state). Only
          # the label goes through the flat pass below; the state itself is drawn
          # after it so it can take its own palette colour.
          STATE_LABEL,
          "",
        ]
        eqp = a.equipment
        @slots.each_with_index { |label, i| lines.push("#{label}: #{item_name(eqp[i])}") }
        # RPG_RT always shows the party's own Gold on this screen -- per
        # EasyRPG Player's source (NOT independently confirmed against
        # genuine RPG_RT under wine), its own `Window_Gold`
        # (`src/window_gold.cpp`) sits right under the actor-info box, drawn
        # unconditionally by `Scene_Status::Start` (`src/scene_status.cpp`,
        # no visibility gate anywhere in the file) -- this screen was missing
        # it here entirely before this line was added, not merely
        # mispositioning it. `DrawCurrencyValue` (`src/window_base.cpp`)
        # draws just the amount and the term, no extra label of its own.
        lines.push("#{@state.party.gold}#{term(:gold, 'G')}")
        lines.each_with_index do |line, i|
          c.draw_text 0, i * LINE_H, inner_w, LINE_H, line
        end
        draw_hp_mp_row c, a, HP_MP_ROW * LINE_H, inner_w
        draw_actor_state c, a, STATE_VALUE_X, STATE_ROW * LINE_H,
                         inner_w - STATE_VALUE_X, LINE_H, @skin
        draw_battle_row(c, a, inner_w) if rpg2003_party?
        @window.contents = c
      end

      # RPG_RT's own status screen additionally shows which RPG2003 battle
      # row the displayed actor is currently in -- ported from EasyRPG
      # Player's source, NOT independently confirmed against genuine RPG_RT
      # under wine: `Window_ActorInfo::DrawInfo` (`src/window_actorinfo.cpp`):
      # `if (Feature::HasRow()) { ... TextDraw(width, 2, ..., battle_row,
      # AlignRight); }`, right-aligned at the top of the panel, above the
      # face/name block. `Feature::HasRow` (`src/feature.cpp`) reduces to
      # "the database is RPG2003" for a genuine, unmodified project (its
      # other half is an EasyRPG-only battlecommands flag with no real LCF
      # field), so this is gated the same way the rest of this codebase
      # gates RPG2003-only presentation: `@state.party.rpg2003?`.
      # `easyrpg_status_scene_back/front` are likewise EasyRPG-only Term
      # extensions absent from RPG_RT's own Term chunk, so real RPG_RT
      # hardcodes the literal English "Front"/"Back" -- matching this file's
      # own `"Class: ..."` precedent for the same situation.
      def rpg2003_party?
        @state.party.respond_to?(:rpg2003?) && @state.party.rpg2003?
      end

      # This screen's HP/MP row: ported from EasyRPG Player's source, NOT
      # independently confirmed against genuine RPG_RT under wine --
      # `Window_ActorStatus::DrawStatus` (`src/window_actorstatus.cpp`)
      # draws it through the same `DrawActorHp`/`DrawActorSp`
      # (`src/window_base.cpp`) the battle status panel uses, so it carries
      # the identical per-value colouring (see Scene::Base
      # #draw_stat_segment) -- only ever applied to this screen's *current*
      # HP/MP figures, never their label or max.
      def draw_hp_mp_row(c, a, y, inner_w)
        gutter = c.text_size('    ').width
        x = draw_stat_segment(c, 0, y, inner_w, LINE_H, term(:hp_short, 'HP') + ' ',
                               a.hp, a.display_max_hp, true, @skin)
        draw_stat_segment(c, x + gutter, y, inner_w, LINE_H, term(:mp_short, 'MP') + ' ',
                           a.mp, a.display_max_mp, false, @skin)
      end

      def draw_battle_row(bmp, actor, inner_w)
        back = actor.respond_to?(:battle_row) && actor.battle_row == Game::Battle::ROW_BACK
        text = back ? 'Back' : 'Front'
        w = bmp.text_size(text).width
        bmp.draw_text inner_w - w, 0, w, LINE_H, text
      end
    end

  end
end
