module RPG2k3
  module Scene
    # RPG2003 battle scene. It subclasses the RPG2000 Scene::Battle so it
    # inherits the entire command / target-cursor / animation machinery --
    # which is already edition-agnostic, since the RPG2003 battle commands are
    # ported (ADR 0048) and the database decode is id-driven. Only the *timing*
    # layer is overridden, keeping the 2000 battle completely untouched.
    #
    # For a gauge (active-time) presentation (battle_type 2) the fight runs on
    # the per-combatant charge gauge (ADR 0053 Phase 2's model, driven by the
    # per-frame turn cycle here): every combatant's gauge fills each frame, the
    # moment one is full decides *whose turn it is* instead of the 2000
    # sequential round order, and acting resets it so it refills. A
    # controllable party member whose gauge is full opens the command menu;
    # everyone else acts automatically the instant their gauge fires, enemy AI
    # included. How long that command menu lets the fight run is the RPG2003
    # Wait/active toggle (`SaveSystem.atb_mode`, LSD chunk 140): in active mode
    # (the default) the gauges keep filling while the menu is open and a ready
    # non-controllable combatant's action interrupts it, in wait mode they
    # freeze (#atb_accumulating? / #drive_battle_command's override) --
    # confirmed against liblcf's own generated `AtbMode` enum
    # (`AtbMode_atb_active = 0, AtbMode_atb_wait = 1`), the opposite of an
    # earlier, uncited pass here that had the two raw values swapped.
    #
    # The traditional (0) and alternative (1) presentations run the inherited
    # turn-based machine unchanged -- every override below is gated on
    # `battle_type == 2`, so routing every 2003 fight through this scene stays
    # safe for them.
    class Battle < RPG2k::Scene::Battle
      # The gauge phases that count as "the command menu is open" for the
      # wait/active toggle, named after EasyRPG Player's State_SelectCommand /
      # SelectItem / SelectSkill / SelectEnemyTarget / SelectAllyTarget (NOT
      # independently confirmed against genuine RPG_RT under wine): in wait mode
      # gauges freeze here, in active mode they keep filling.
      ATB_MENU_PHASES = [:command, :target, :skill, :item, :ally_target].freeze

      # Whether this fight runs in RPG2003's active-during-menu (Wait-off)
      # presentation -- the save-system `atb_mode` toggle (LSD chunk 140),
      # flipped by the field menu's Wait command (id 8). Active mode (the
      # default, raw 0 -- liblcf's `AtbMode_atb_active`) keeps the gauges
      # filling while a command menu is open; wait mode (raw 1,
      # `AtbMode_atb_wait`) freezes them.
      def active_atb?
        gauge_battle? && @state.atb_mode != 1
      end

      # Whether the active-time gauges advance this frame -- ported from
      # EasyRPG Player's `IsAtbAccumulating` (src/scene_battle_rpg2k3.cpp),
      # NOT independently confirmed against genuine RPG_RT under wine: always in the
      # idle loop (SelectActor / AutoBattle), only in active mode while a
      # command/target/skill/item menu is open, and never during action
      # resolution, the encounter banner or a battle event.
      def atb_accumulating?
        phase = @ui[:phase]
        return true if phase == :atb
        return active_atb? if ATB_MENU_PHASES.include?(phase)
        false
      end

      # Advance the active-time gauge every frame for a gauge battle, then
      # dispatch on the phase. A turn-based or alternative battle leaves the
      # gauge at 0 and runs the inherited update (and with it the whole 2000
      # round machine) untouched.
      def update
        battle = @ui && @ui[:battle]
        if battle && battle.battle_type == 2
          battle.advance_gauges if atb_accumulating?
          update_enemy_flashes
          update_enemy_positions
          update_enemy_shakes
          case @ui[:phase]
          when :encounter_message then drive_battle_encounter_message
          # The active-time idle loop -- the phase the gauge battle lives in
          # between actions, and the replacement for the round machine's
          # :command/:battle_options pair (see #enter_command_phase).
          when :atb         then drive_battle_atb
          when :command     then drive_battle_command
          when :target      then drive_battle_target
          when :skill       then drive_battle_skill
          when :item        then drive_battle_item
          when :ally_target then drive_battle_ally_target
          when :animate     then drive_battle_animate
          when :result      then drive_battle_result
          when :event       then drive_battle_event
          end
          @map.try_open_debug_menu
        else
          super
        end
      end

      # Whether this fight is the gauge presentation -- the gate every override
      # here checks, so the 2003 scene's traditional (0) and alternative (1)
      # battles inherit the untouched 2000 machine. A bare fixture battle that
      # never set a battle_type reads 0 (false), like every other optional
      # field in this codebase.
      def gauge_battle?
        battle = @ui && @ui[:battle]
        !!(battle && battle.battle_type == 2)
      end

      # The gauge battle's "whose turn is it": poll the ready combatants (the
      # full-gauge ones, highest first) and hand the frame to whichever one
      # fires. A living, in-play party member free to take a manual command
      # opens the command menu for it -- its gauge stays full, held, until it
      # commits -- and anyone else (an enemy, an asleep/paralysed or Forced-AI
      # actor) acts automatically right away. Battle-event pages are checked
      # once per acting battler the way the round machine checks them between
      # battlers, and a decided fight settles to its result.
      def drive_battle_atb
        battle = @ui[:battle]
        return if run_battle_events(:atb)
        if battle.finished?
          # #finish_round_animation settles the result before returning here,
          # but the per-frame loop should not trust that: settle it defensively
          # (end_round is idempotent) so a fight that became decided another
          # way -- a battle-event page, say -- lands on its result, never on a
          # nil one.
          battle.end_round
          enter_battle_result(battle.result)
          return
        end
        b = battle.ready_combatants.first
        return unless b
        if controllable?(b)
          # Point the command flow at the ready actor (`current_actor` reads
          # @ui[:actor_i]) and open its menu; the gauge stays full while the
          # player chooses.
          idx = living_allies.index(b)
          @ui[:actor_i] = idx if idx
          @ui[:cmd] = 0
          @ui[:phase] = :command
          draw_battle_command
        else
          # A Forced-AI actor's ready gauge gets the same AI pick the round
          # machine's skip logic would have queued for it; a restricted actor
          # just fires its turn (which #step_action resolves to a no-op).
          battle.choose_auto_battle_command(b) if force_ai_actor?(b)
          start_gauge_action(b)
        end
      end

      # The gauge battle's replacement for the once-per-fight Fight/Auto/Escape
      # options window: there is none -- the first ready controllable actor's
      # command menu opens on its own the moment its gauge fills. Both the
      # battle-start entry (#start's own final step) and the between-actions
      # re-entry route here.
      def enter_command_phase
        return enter_atb_phase if gauge_battle?
        super
      end

      # The command menu's cancel lands here too: a gauge battle offers no
      # Fight/Auto/Escape window to fall back to, so canceling the ready
      # actor's menu simply returns it to the idle loop -- its gauge stays full
      # and it is offered the menu again.
      def open_battle_options
        return enter_atb_phase if gauge_battle?
        super
      end

      # A gauge battle's command-cancel never re-commands a *previous* party
      # member the way the round machine does (only the ready actor is ever
      # offered a menu); it always returns to the active-time idle loop. The
      # base #drive_battle_command reads this to decide where B lands.
      def prev_commandable_actor_index
        return nil if gauge_battle?
        super
      end

      # The command flow's "next actor" is the round machine's job. A gauge
      # battle instead starts the ready actor's action the moment its command
      # commits -- every command path (Attack/Skill/Defend/Item, each of the
      # target/skill/item sub-menus) funnels through this one method.
      def advance_actor
        return start_gauge_action(current_actor) if gauge_battle? && current_actor
        super
      end

      # A gauge battle's command menu, with the Wait/active toggle honoured:
      # in active mode a ready combatant whose action would fire on its own
      # (an enemy, or a restricted / Forced-AI actor -- anyone the idle loop
      # would act automatically rather than prompt) interrupts the menu
      # instead of waiting behind it. Ported from EasyRPG Player's source,
      # NOT independently confirmed against genuine RPG_RT under wine: its
      # own `ProcessSceneActionCommand`
      # does exactly this: `if (GetAtbMode() == AtbMode_atb_active &&
      # IsBattleActionPending()) SetState(State_Battle)`. The interrupting
      # turn plays out, then -- because the commanded actor's gauge is still
      # held full -- the idle loop reopens its menu. In wait mode this check
      # is skipped and the menu stays up until the player commits, matching
      # the reference's `IsBattleActionPending` gate being ANDed with active
      # mode only.
      def drive_battle_command
        if gauge_battle? && active_atb? && (b = interrupting_ready_combatant)
          start_gauge_action(b)
          return
        end
        super
      end

      # The ready combatant whose action is pending behind the command menu in
      # active mode: the first full-gauge battler the idle loop would act
      # automatically -- i.e. not the actor whose menu is up and not one a
      # controllable party member whose own menu would simply wait its turn.
      def interrupting_ready_combatant
        battle = @ui[:battle]
        cur = current_actor
        battle.ready_combatants.find { |c| c != cur && !controllable?(c) }
      end

      # The gauge battle's counterpart to #start_round_animation: begin the one
      # ready combatant's action (its gauge already consumed by the model) in
      # place of a whole agility-ordered round. From here #drive_battle_animate
      # plays it out exactly as it plays a round -- banner, SE, animation,
      # battle-page checks at the action boundary -- then the queue emptying
      # returns the fight to the idle loop (#finish_round_animation's override).
      #
      # `battler_boundary` is armed so the *first* gauge action of a turn gets
      # the per-battler page check too: #drive_battle_animate only runs that
      # check on a set boundary, and a fresh gauge action has none of its own
      # yet (the flag is normally set by the *previous* action's step_action).
      def start_gauge_action(b)
        if @ui[:cmd_win]
          @ui[:cmd_win].dispose
          @ui[:cmd_win] = nil
        end
        @ui[:battle].begin_gauge_turn(b)
        @ui[:battler_boundary] = true
        @ui[:phase] = :animate
        @ui[:anim_timer] = 0 # land the action next frame
      end

      # A gauge action is its own "round": when the queue empties, return to
      # the active-time idle loop rather than opening the next round's command
      # window. The per-action `pages_run` reset matches the base's per-round
      # reset -- each battler's turn re-arms the troop's pages.
      def finish_round_animation
        return super unless gauge_battle?
        battle = @ui[:battle]
        # See the base #finish_round_animation's identical comment: snapshot
        # who is showing the Defend pose before `end_round` clears the flag,
        # so their sprite can revert to Idle, and catch up anyone felled
        # this action onto the Dead pose.
        defenders = @ui[:allies].select(&:defending)
        battle.end_round
        (defenders + @ui[:allies].select(&:dead?)).uniq { |a| a.object_id }
          .each { |ally| reposition_actor_sprite(ally) }
        close_battle_action
        if battle.finished?
          enter_battle_result(battle.result)
        else
          @ui[:actor_i] = 0
          @ui[:cmd] = 0
          @ui[:pages_run] = {}
          enter_atb_phase
        end
      end

      # Enter the active-time idle loop and give it the rest of this frame, so
      # an action ending and the next ready combatant firing never costs a
      # whole extra frame -- the same "spend this frame's step budget
      # immediately" idiom the base's own #finish_round_animation uses to open
      # the next command window. #drive_battle_atb runs the page/finished/ready
      # checks itself, so this just points the phase at it.
      def enter_atb_phase
        @ui[:phase] = :atb
        return if settle_already_finished_battle
        drive_battle_atb
      end

      # Whether `b` is a living, in-play *party member* free to be handed a
      # manual command right now -- an enemy is never offered a menu (its ready
      # gauge always fires its own AI action), and the "commandable" test the
      # round machine's own skip logic uses for the allies it does offer one to
      # (`#command_restricted?` + the scene's Forced-AI test) decides the rest,
      # so an asleep / paralysed / Forced-AI actor's ready gauge fires its
      # action automatically instead of pausing the fight for a prompt the
      # action resolution would discard or override anyway.
      def controllable?(b)
        return false unless @ui[:allies].include?(b)
        battle = @ui[:battle]
        !battle.command_restricted?(b) && !force_ai_actor?(b)
      end
    end
  end
end
