# RPG2000 event command interpreter.
#
# Runs a decoded event command list (LCF::EventCommand array) against the game
# State. Commands that only change state (switches, variables, party, gold,
# items, conditional branches) are applied directly and are unit-testable
# without any RGSS/UI. Commands that need the UI or the map (messages, choices,
# waits, teleports) do not block here: the interpreter records the request,
# raises its `waiting?` flag and pauses; the owning scene reads the request,
# drives the UI, and calls `resume` (or `choose`) to continue.
module Game
  class Interpreter
    # RPG2000 event command opcodes (subset).
    module Cmd
      SHOW_MESSAGE     = 10110
      MESSAGE_2        = 20110
      MESSAGE_OPTIONS  = 10120
      CHANGE_FACE      = 10130
      SHOW_CHOICES     = 10140
      CHOICE_OPTION    = 20140
      CHOICE_END       = 20141
      INPUT_NUMBER     = 10150
      NAME_INPUT       = 10740
      KEY_INPUT_PROC   = 11610
      CONTROL_SWITCHES = 10210
      CONTROL_VARS     = 10220
      TIMER_OPERATION  = 10230
      CHANGE_GOLD      = 10310
      CHANGE_ITEMS     = 10320
      CHANGE_PARTY     = 10330
      CHANGE_EXP       = 10410
      CHANGE_LEVEL     = 10420
      CHANGE_PARAM     = 10430
      CHANGE_EQUIP     = 10440
      CHANGE_HP        = 10460
      CHANGE_MP        = 10470
      CHANGE_CONDITION = 10480
      FULL_HEAL        = 10490
      CHANGE_ACTOR_NAME   = 10610
      CHANGE_ACTOR_TITLE  = 10620
      CHANGE_ACTOR_SPRITE = 10630
      CHANGE_SYSTEM_GFX   = 10680
      CHANGE_SYSTEM_BGM   = 10660
      CHANGE_SYSTEM_SFX   = 10670
      CHANGE_TRANSITION   = 10690
      ENEMY_ENCOUNTER  = 10710
      VICTORY_HANDLER  = 20710
      ESCAPE_HANDLER   = 20711
      DEFEAT_HANDLER   = 20712
      END_BATTLE       = 20713
      OPEN_SHOP           = 10720
      SHOP_TRANSACTION    = 20720
      SHOP_NO_TRANSACTION = 20721
      SHOP_END            = 20722
      SHOW_INN         = 10730
      INN_STAY         = 20730
      INN_NO_STAY      = 20731
      INN_END          = 20732
      MEMORIZE_LOCATION = 10820
      RECALL_LOCATION   = 10830
      CHANGE_EVENT_LOCATION = 10860
      TRADE_EVENT_LOCATIONS = 10870
      STORE_TERRAIN_ID  = 10910
      STORE_EVENT_ID    = 10920
      CONDITIONAL      = 12010
      ELSE_BRANCH      = 22010
      END_BRANCH       = 22011
      LABEL            = 12110
      JUMP_TO_LABEL    = 12120
      LOOP             = 12210
      BREAK_LOOP       = 12220
      END_LOOP         = 22210
      COMMENT          = 12410
      COMMENT_2        = 22410
      END_EVENT        = 12310
      ERASE_EVENT      = 12320
      CALL_EVENT       = 12330
      TELEPORT         = 10810
      ERASE_SCREEN     = 11010
      SHOW_SCREEN      = 11020
      TINT_SCREEN      = 11030
      FLASH_SCREEN     = 11040
      SHAKE_SCREEN     = 11050
      PAN_SCREEN       = 11060
      WEATHER_EFFECTS  = 11070
      SHOW_PICTURE     = 11110
      MOVE_PICTURE     = 11120
      ERASE_PICTURE    = 11130
      PLAYER_VISIBILITY = 11310
      MOVE_EVENT       = 11330
      PROCEED_WITH_MOVEMENT = 11340
      HALT_ALL_MOVEMENT = 11350
      WAIT             = 11410
      PLAY_BGM         = 11510
      MEMORIZE_BGM     = 11530
      PLAY_MEMORIZED_BGM = 11540
      PLAY_SE          = 11550
      CHANGE_MAP_TILESET = 11710
      CHANGE_ENCOUNTER_RATE = 11740
      SET_TELEPORT_TARGET = 11810
      CHANGE_TELEPORT_ACCESS = 11820
      SET_ESCAPE_TARGET   = 11830
      CHANGE_ESCAPE_ACCESS   = 11840
      CHANGE_SAVE_ACCESS = 11930
      CHANGE_MENU_ACCESS = 11960
      RETURN_TO_TITLE  = 12510
      GAME_OVER        = 12520
    end

    # Move-command ids inside a Move Event that carry extra parameters (every
    # other id is a bare command). Mirrors LCF's move-route parameter layout.
    module MoveCmd
      SWITCH_ON      = 32 # + switch id
      SWITCH_OFF     = 33 # + switch id
      CHANGE_GRAPHIC = 34 # + charset name (string) + charset index
      PLAY_SOUND     = 35 # + file name (string) + volume, tempo, balance
    end

    # Upper bound on nested Call Event depth, so a common event that (directly or
    # indirectly) calls itself unwinds instead of growing the stack without end.
    MAX_CALL_DEPTH = 100

    def initialize(state)
      @state = state
      @list = []
      @index = 0
      @running = false
      @call_stack = []
      @resolver = nil
      @move_route_requests = []
      @location_requests = []
      @erase_requested = false
      @halt_movement_requested = false
      @actor_graphic_changed = false
      @tileset_request = nil
      @input_variable = nil
      @input_digits = 1
      # Deterministic RNG for the Control Variables "random" operand (mruby has
      # no Kernel#rand here); seeded like the map scene's own RNG.
      @rng = Game::Rng.new(0x2000)
      reset_waits
    end

    def running?; @running; end
    def waiting?; @waiting; end
    attr_reader :wait_kind, :message_lines, :choice_labels, :wait_frames,
                :teleport, :input_digits, :key_input_request, :inn_request,
                :shop_request, :battle_request, :name_input_request
    # Resolves the command list a Call Event refers to (a common event, or a page
    # of a map event). Set by the owning scene; nil disables Call Event.
    attr_accessor :resolver
    # Answers tile queries for Store Terrain / Event ID: responds to
    # `terrain_id(x, y)` and `event_id_at(x, y)`. Set by the owning scene; nil
    # makes those commands store 0 (the map is not queryable without it).
    attr_accessor :map_info

    def start(commands)
      @list = commands || []
      @index = 0
      @running = true
      @call_stack = []
      @move_route_requests = []
      @location_requests = []
      @erase_requested = false
      @halt_movement_requested = false
      @actor_graphic_changed = false
      @system_graphic_changed = false
      @tileset_request = nil
      # Messages queued by a stat command (a Change Level / Change EXP with its
      # "show message" flag set) and shown one after another before the event
      # continues. Drained by #resume, so it survives the reset_waits between
      # messages; abandoned by #stop.
      @pending_messages = []
      reset_waits
    end

    # Drain the Move Event (Set Move Route) requests queued since the last call,
    # returning them (each a hash: target, frequency, repeat, skippable,
    # commands) and clearing the queue. Unlike message/wait/teleport, a Move
    # Event does not pause the interpreter — the route runs in the background —
    # so the owning scene polls this after each #update to apply the routes to
    # the target characters.
    def take_move_route_requests
      reqs = @move_route_requests
      @move_route_requests = []
      reqs
    end

    # Drain the instant event-repositioning requests (Change Event Location /
    # Trade Event Locations) queued since the last call, returning them and
    # clearing the queue. Each is a hash — `{ op: :set, target:, x:, y: }` or
    # `{ op: :swap, a:, b: }`. Like Move Event these do not pause the interpreter;
    # the owning scene polls this after #update and moves the characters.
    def take_location_requests
      reqs = @location_requests
      @location_requests = []
      reqs
    end

    # True (once) if an Erase Event command ran since the last call, clearing the
    # flag. The owning scene polls this after #update and removes the event that
    # was running this interpreter from the map. Like Move Event, Erase Event does
    # not pause the interpreter — the rest of the command list still runs.
    def take_erase_request
      v = @erase_requested
      @erase_requested = false
      v
    end

    # The new tileset (chipset) id requested by a Change Map Tileset command since
    # the last call, or nil if none. Reading it clears the request. The owning
    # scene polls this after #update and rebuilds the map's chipset; non-blocking,
    # so the rest of the command list runs on.
    def take_tileset_request
      id = @tileset_request
      @tileset_request = nil
      id
    end

    # True (once) if a Halt All Movement command ran since the last call, clearing
    # the flag. The owning scene polls this after #update and cancels every forced
    # move route in progress (the player's and each event's). Non-blocking, like
    # Erase Event: the rest of the command list keeps running.
    def take_halt_movement_request
      v = @halt_movement_requested
      @halt_movement_requested = false
      v
    end

    # True (once) if a Change Sprite Association (Change Actor Graphic) command
    # ran since the last call, clearing the flag. The owning scene polls this
    # after #update and reloads the party leader's on-screen sprite so a mid-event
    # graphic change is reflected. Non-blocking.
    def take_actor_graphic_changed
      v = @actor_graphic_changed
      @actor_graphic_changed = false
      v
    end

    # Drain the one-shot Change System Graphics (10680) request so the scene
    # reloads the windowskin. Non-blocking.
    def take_system_graphic_changed
      v = @system_graphic_changed
      @system_graphic_changed = false
      v
    end

    # Upper bound on commands run in a single update, so a malformed loop cannot
    # hang the game loop.
    MAX_STEPS = 1_000_000

    # Advance through commands until the list ends or a command asks to wait.
    # When the current (possibly called) list runs out, control returns to the
    # caller via the call stack; the process ends only once the outermost list is
    # exhausted.
    def update
      return unless @running
      steps = 0
      until @waiting
        # Unwind any exhausted called lists back to a caller with commands left.
        return_from_call while @index >= @list.size && !@call_stack.empty?
        break if @index >= @list.size # nothing left anywhere
        cmd = @list[@index]
        @index += 1
        execute cmd
        steps += 1
        break if steps >= MAX_STEPS
      end
      @running = false if finished?
    end

    # True when nothing is left to run: the current list is exhausted, no caller
    # is waiting on the stack, and we are not paused on a UI/map request.
    def finished?
      @index >= @list.size && @call_stack.empty? && !@waiting
    end

    # Resume the caller that a finished called-list returned to; returns false
    # when there is no caller (the outermost list is done).
    def return_from_call
      return false if @call_stack.empty?
      @list, @index = @call_stack.pop
      true
    end

    # Resume after a message/wait/teleport request has been handled.
    def resume
      # A stat command may have queued several level-up messages; show the next
      # one instead of continuing until the queue drains.
      return if show_next_pending_message
      reset_waits
    end

    # Abandon the rest of the current command list (e.g. after a teleport),
    # including any pending callers.
    def stop
      @running = false
      @index = @list.size
      @call_stack = []
      @pending_messages = []
      reset_waits
    end

    # Resume a choice, jumping into the selected option's branch.
    def choose(index)
      target = find_choice_option(index)
      @index = target if target
      reset_waits
    end

    # Resume an Input Number request: store the entered `value` into the target
    # variable and continue. The owning scene drives a digit-entry widget while
    # the interpreter is paused on the :number wait, then calls this with the
    # number the player entered.
    def resume_number(value)
      variables[@input_variable] = value.to_i if @input_variable
      reset_waits
    end

    # Resume Enter Hero Name (10740): rename the target actor to the entered
    # `name` (a blank entry keeps the previous name, as RPG_RT does) and continue.
    # The owning scene drives the character-entry widget while the interpreter is
    # paused on the :name_input wait, then calls this with the entered name.
    def resume_name_input(name)
      req = @name_input_request
      actor = req && party.actor_by_id(req[:actor_id])
      actor.name = name if actor && name && !name.empty?
      reset_waits
    end

    # Resume a Key Input Processing request: store the pressed key's RPG2000
    # `code` (0 when nothing matched, only reached in no-wait mode) into the
    # target variable and continue. The owning scene samples input while the
    # interpreter is paused on the :key_input wait, then calls this.
    def resume_key_input(code)
      variables[@input_variable] = code.to_i if @input_variable && @input_variable > 0
      reset_waits
    end

    # Resume a Show Inn request with the player's decision. On a stay: charge the
    # inn price and fully heal the party (HP and MP). Either way, if the event
    # carries [Stay] / [No Stay] handler sub-branches, jump into the matching one;
    # otherwise execution simply continues past the command. The owning scene
    # shows the greeting / choice prompt while the interpreter is paused on the
    # :inn wait, then calls this.
    def resume_inn(stayed)
      if stayed
        party.gain_gold(-@inn_price) if @inn_price && @inn_price > 0
        party.actors.each(&:full_heal)
      end
      if @inn_has_handlers
        target = find_inn_option(stayed)
        @index = target if target
      end
      reset_waits
    end

    # Locate the [Stay] (INN_STAY) or [No Stay] (INN_NO_STAY) handler branch for
    # the pending inn, returning the index just after its marker. Falls back to
    # the INN_END marker (so an absent branch runs nothing) and to nil once the
    # inn's own indent level is left without a match.
    def find_inn_option(stay)
      want = stay ? Cmd::INN_STAY : Cmd::INN_NO_STAY
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @inn_indent && c.code == want
        return i if c.indent == @inn_indent && c.code == Cmd::INN_END
        return nil if c.indent < @inn_indent
        i += 1
      end
      nil
    end

    # Resume an Open Shop request once the player leaves the shop. `transacted`
    # is whether anything was actually bought or sold — the buying and selling
    # (gold and inventory changes) happen in the shop scene, mirroring RPG_RT.
    # When the event carries [Transaction] / [No Transaction] handler branches,
    # jump into the matching one; otherwise execution simply continues.
    def resume_shop(transacted)
      if @shop_has_handlers
        target = find_shop_option(transacted)
        @index = target if target
      end
      reset_waits
    end

    # Locate the [Transaction] (SHOP_TRANSACTION) or [No Transaction]
    # (SHOP_NO_TRANSACTION) handler branch for the pending shop, returning the
    # index just after its marker. Falls back to SHOP_END and to nil once the
    # shop's own indent level is left — the same structure as the inn branches.
    def find_shop_option(transacted)
      want = transacted ? Cmd::SHOP_TRANSACTION : Cmd::SHOP_NO_TRANSACTION
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @shop_indent && c.code == want
        return i if c.indent == @shop_indent && c.code == Cmd::SHOP_END
        return nil if c.indent < @shop_indent
        i += 1
      end
      nil
    end

    # Resume an Enemy Encounter with the battle's outcome (:victory, :escape or
    # :defeat). Rewards (EXP / gold on victory) are granted by the scene, which
    # owns the battle; this only steers event flow. Escape with the "end event
    # processing" mode abandons the rest of the event; otherwise, when the
    # command carries [Victory] / [Escape] / [Defeat] handler branches, jump into
    # the matching one. A game-over on defeat is the scene's concern.
    def resume_battle(result)
      if result == :escape && @battle_escape_aborts
        @index = @list.size
        @call_stack = []
        reset_waits
        return
      end
      if @battle_has_handlers
        target = find_battle_option(result)
        @index = target if target
      end
      reset_waits
    end

    BATTLE_HANDLERS = { victory: Cmd::VICTORY_HANDLER, escape: Cmd::ESCAPE_HANDLER,
                        defeat: Cmd::DEFEAT_HANDLER }.freeze

    # Locate the handler branch for a battle outcome, like the inn / shop
    # branches: the index just after its marker, falling back to END_BATTLE and
    # to nil once the encounter's indent level is left.
    def find_battle_option(result)
      want = BATTLE_HANDLERS[result]
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @battle_indent && c.code == want
        return i if c.indent == @battle_indent && c.code == Cmd::END_BATTLE
        return nil if c.indent < @battle_indent
        i += 1
      end
      nil
    end

    # RPG2000 key-input result codes in priority order (highest first). When more
    # than one accepted button is active RPG_RT returns the largest code:
    # Shift > Cancel > Decision > Up > Right > Left > Down.
    KEY_INPUT_CODES = [
      [:shift, 7], [:cancel, 6], [:decision, 5],
      [:up, 4], [:right, 3], [:left, 2], [:down, 1]
    ].freeze

    # Given the set of currently-active key symbols (an array like [:decision]),
    # return the RPG2000 code of the highest-priority key the pending request
    # accepts, or 0 when none of the accepted keys are active. Called by the
    # owning scene once it has sampled real input.
    def key_input_result(active)
      acc = @key_input_request && @key_input_request[:accepted]
      return 0 unless acc
      KEY_INPUT_CODES.each do |sym, code|
        return code if acc[sym] && active.include?(sym)
      end
      0
    end

    private

    def reset_waits
      @waiting = false
      @wait_kind = nil
      @message_lines = nil
      @choice_labels = nil
      @wait_frames = 0
      @teleport = nil
      @key_input_request = nil
      @inn_request = nil
      @shop_request = nil
      @battle_request = nil
      @name_input_request = nil
    end

    def switches;  @state.switches;  end
    def variables; @state.variables; end
    def party;     @state.party;     end

    def execute(cmd)
      case cmd.code
      when Cmd::SHOW_MESSAGE     then do_show_message cmd
      when Cmd::MESSAGE_OPTIONS  then do_message_options cmd
      when Cmd::CHANGE_FACE      then do_change_face cmd
      when Cmd::SHOW_CHOICES     then do_show_choices cmd
      when Cmd::CHOICE_OPTION    then skip_to([Cmd::CHOICE_END], cmd.indent); consume
      when Cmd::CHOICE_END       then nil
      when Cmd::INPUT_NUMBER     then do_input_number cmd
      when Cmd::KEY_INPUT_PROC   then do_key_input cmd
      when Cmd::ENEMY_ENCOUNTER  then do_enemy_encounter cmd
      when Cmd::VICTORY_HANDLER  then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::ESCAPE_HANDLER   then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::DEFEAT_HANDLER   then skip_to([Cmd::END_BATTLE], cmd.indent); consume
      when Cmd::END_BATTLE       then nil
      when Cmd::OPEN_SHOP        then do_open_shop cmd
      when Cmd::SHOP_TRANSACTION    then skip_to([Cmd::SHOP_END], cmd.indent); consume
      when Cmd::SHOP_NO_TRANSACTION then skip_to([Cmd::SHOP_END], cmd.indent); consume
      when Cmd::SHOP_END         then nil
      when Cmd::NAME_INPUT       then do_name_input cmd
      when Cmd::SHOW_INN         then do_show_inn cmd
      when Cmd::INN_STAY         then skip_to([Cmd::INN_END], cmd.indent); consume
      when Cmd::INN_NO_STAY      then skip_to([Cmd::INN_END], cmd.indent); consume
      when Cmd::INN_END          then nil
      when Cmd::CONTROL_SWITCHES then do_control_switches cmd
      when Cmd::CONTROL_VARS     then do_control_vars cmd
      when Cmd::TIMER_OPERATION  then do_timer cmd
      when Cmd::CHANGE_GOLD      then do_change_gold cmd
      when Cmd::CHANGE_ITEMS     then do_change_items cmd
      when Cmd::CHANGE_PARTY     then do_change_party cmd
      when Cmd::CHANGE_EXP       then do_change_exp cmd
      when Cmd::CHANGE_LEVEL     then do_change_level cmd
      when Cmd::CHANGE_PARAM     then do_change_params cmd
      when Cmd::CHANGE_EQUIP     then do_change_equipment cmd
      when Cmd::CHANGE_HP        then do_change_hp cmd
      when Cmd::CHANGE_MP        then do_change_mp cmd
      when Cmd::CHANGE_CONDITION then do_change_condition cmd
      when Cmd::FULL_HEAL        then do_full_heal cmd
      when Cmd::CHANGE_ACTOR_NAME   then do_change_actor_name cmd
      when Cmd::CHANGE_ACTOR_TITLE  then do_change_actor_title cmd
      when Cmd::CHANGE_ACTOR_SPRITE then do_change_actor_sprite cmd
      when Cmd::CONDITIONAL      then do_conditional cmd
      when Cmd::ELSE_BRANCH      then skip_to([Cmd::END_BRANCH], cmd.indent); consume
      when Cmd::END_BRANCH       then nil
      when Cmd::JUMP_TO_LABEL    then do_jump_label cmd
      when Cmd::LOOP             then nil # marker; body runs, END_LOOP loops back
      when Cmd::BREAK_LOOP       then do_break_loop cmd
      when Cmd::END_LOOP         then do_end_loop cmd
      when Cmd::TELEPORT         then do_teleport cmd
      when Cmd::MEMORIZE_LOCATION then do_memorize_location cmd
      when Cmd::RECALL_LOCATION   then do_recall_location cmd
      when Cmd::CHANGE_EVENT_LOCATION then do_change_event_location cmd
      when Cmd::TRADE_EVENT_LOCATIONS then do_trade_event_locations cmd
      when Cmd::STORE_TERRAIN_ID  then do_store_terrain_id cmd
      when Cmd::STORE_EVENT_ID    then do_store_event_id cmd
      when Cmd::ERASE_SCREEN     then do_erase_screen cmd
      when Cmd::SHOW_SCREEN      then do_show_screen cmd
      when Cmd::TINT_SCREEN      then do_tint_screen cmd
      when Cmd::FLASH_SCREEN     then do_flash_screen cmd
      when Cmd::SHAKE_SCREEN     then do_shake_screen cmd
      when Cmd::PAN_SCREEN       then do_pan_screen cmd
      when Cmd::SHOW_PICTURE     then do_show_picture cmd
      when Cmd::MOVE_PICTURE     then do_move_picture cmd
      when Cmd::ERASE_PICTURE    then do_erase_picture cmd
      when Cmd::WEATHER_EFFECTS  then do_weather cmd
      when Cmd::PLAYER_VISIBILITY then do_player_visibility cmd
      when Cmd::MOVE_EVENT       then do_move_event cmd
      when Cmd::PROCEED_WITH_MOVEMENT then do_proceed_with_movement cmd
      when Cmd::HALT_ALL_MOVEMENT then @halt_movement_requested = true
      when Cmd::WAIT             then do_wait cmd
      when Cmd::PLAY_BGM         then play_audio(:bgm, cmd)
      when Cmd::MEMORIZE_BGM     then do_memorize_bgm cmd
      when Cmd::PLAY_MEMORIZED_BGM then do_play_memorized_bgm cmd
      when Cmd::PLAY_SE          then play_audio(:se, cmd)
      when Cmd::CHANGE_MAP_TILESET then @tileset_request = cmd.param(0)
      when Cmd::CHANGE_ENCOUNTER_RATE then @state.encounter_rate = cmd.param(0)
      when Cmd::SET_TELEPORT_TARGET then do_set_teleport_target cmd
      when Cmd::SET_ESCAPE_TARGET   then do_set_escape_target cmd
      when Cmd::CHANGE_SYSTEM_GFX     then do_change_system_graphic cmd
      when Cmd::CHANGE_SYSTEM_BGM    then do_change_system_bgm cmd
      when Cmd::CHANGE_SYSTEM_SFX    then do_change_system_sfx cmd
      when Cmd::CHANGE_TRANSITION    then @state.set_screen_transition(cmd.param(0), cmd.param(1))
      when Cmd::CHANGE_TELEPORT_ACCESS then @state.teleport_access = cmd.param(0) != 0
      when Cmd::CHANGE_ESCAPE_ACCESS then @state.escape_access = cmd.param(0) != 0
      when Cmd::CHANGE_SAVE_ACCESS then @state.save_access = cmd.param(0) != 0
      when Cmd::CHANGE_MENU_ACCESS then @state.menu_access = cmd.param(0) != 0
      when Cmd::RETURN_TO_TITLE  then do_return_to_title cmd
      when Cmd::GAME_OVER        then do_game_over cmd
      when Cmd::CALL_EVENT       then do_call_event cmd
      when Cmd::ERASE_EVENT      then @erase_requested = true
      when Cmd::END_EVENT        then @index = @list.size
      else nil # unimplemented / no-op (labels, comments, ...)
      end
    end

    # Call Event: suspend the current list and run a referenced command list to
    # completion, then resume where we left off. param0 selects what is called:
    #   0 – common event: param1 = common event id
    #   1 – map event:    param1 = event id, param2 = page number
    #   2 – map event, ids taken indirectly from variables
    # A missing/empty target is a no-op; recursion is bounded by MAX_CALL_DEPTH.
    def do_call_event(cmd)
      return unless @resolver
      cmds = resolve_call(cmd)
      return if cmds.nil? || cmds.empty?
      return if @call_stack.size >= MAX_CALL_DEPTH
      @call_stack.push [@list, @index]
      @list = cmds
      @index = 0
    end

    def resolve_call(cmd)
      case cmd.param(0)
      when 0 then @resolver.common_event_commands(cmd.param(1))
      when 1 then @resolver.map_event_commands(cmd.param(1), cmd.param(2))
      when 2 then @resolver.map_event_commands(variables[cmd.param(1)],
                                               variables[cmd.param(2)])
      end
    rescue StandardError
      nil
    end

    # -- flow helpers ---------------------------------------------------------

    # Move @index to the first command at `indent` whose code is in `codes`.
    def skip_to(codes, indent)
      while @index < @list.size
        c = @list[@index]
        break if c.indent == indent && codes.include?(c.code)
        @index += 1
      end
    end

    # Step past the command @index currently points at (a matched marker).
    def consume
      @index += 1 if @index < @list.size
    end

    # Jump to the (first) label command with the given id.
    def do_jump_label(cmd)
      target = cmd.param(0)
      @list.each_with_index do |c, j|
        if c.code == Cmd::LABEL && c.param(0) == target
          @index = j
          return
        end
      end
    end

    # End of loop: jump back to just after the matching Loop marker (same indent).
    def do_end_loop(cmd)
      j = @index - 2 # scan back from before this End Loop
      while j >= 0
        c = @list[j]
        if c.indent == cmd.indent && c.code == Cmd::LOOP
          @index = j + 1
          return
        end
        j -= 1
      end
    end

    # Break Loop: jump past the enclosing loop's End Loop marker.
    def do_break_loop(cmd)
      j = @index
      while j < @list.size
        c = @list[j]
        if c.code == Cmd::END_LOOP && c.indent < cmd.indent
          @index = j + 1
          return
        end
        j += 1
      end
    end

    # -- message / choices ----------------------------------------------------

    def do_show_message(cmd)
      lines = [cmd.string]
      while @index < @list.size && @list[@index].code == Cmd::MESSAGE_2
        lines.push @list[@index].string
        @index += 1
      end
      @message_lines = lines
      @wait_kind = :message
      @waiting = true
    end

    # Message Options: configure the message window for subsequent Show Message
    # commands. param0 transparent background (0 shown / 1 transparent), param1
    # position (0 top / 1 middle / 2 bottom), param2 whether the window may move
    # aside to avoid the hero (0 fixed / 1 auto-position — so `position_fixed`
    # is the param2 == 0 case, matching RPG_RT), param3 whether other events keep
    # running while the message shows. Sets global state; it does not pause.
    def do_message_options(cmd)
      cfg = @state.message_config
      cfg.transparent = cmd.param(0) != 0
      cfg.position = cmd.param(1)
      cfg.position_fixed = cmd.param(2) == 0
      cfg.continue_events = cmd.param(3) != 0
    end

    # Change Face Graphic: select the face shown beside the next messages. The
    # command string is the FaceSet file name (empty clears the face); param0 is
    # the cell index (0..15), param1 puts the face on the right, param2 mirrors
    # it. Persists until changed; does not pause.
    def do_change_face(cmd)
      cfg = @state.message_config
      name = cmd.string || ''
      if name.empty?
        cfg.clear_face
      else
        cfg.face_name = name
        cfg.face_index = cmd.param(0)
        cfg.face_right = cmd.param(1) != 0
        cfg.face_flipped = cmd.param(2) != 0
      end
    end

    def do_show_choices(cmd)
      labels = []
      i = @index
      while i < @list.size
        c = @list[i]
        break if c.indent == cmd.indent && c.code == Cmd::CHOICE_END
        if c.indent == cmd.indent && c.code == Cmd::CHOICE_OPTION
          labels[c.param(0)] = c.string
        end
        i += 1
      end
      @choice_indent = cmd.indent
      @choice_labels = labels.compact
      @wait_kind = :choice
      @waiting = true
    end

    def find_choice_option(index)
      i = @index
      while i < @list.size
        c = @list[i]
        return i + 1 if c.indent == @choice_indent && c.code == Cmd::CHOICE_OPTION && c.param(0) == index
        return i if c.indent == @choice_indent && c.code == Cmd::CHOICE_END
        i += 1
      end
      nil
    end

    # Input Number: RPG2000 lays the parameters out as [digits, variable_id]
    # (note the order is the reverse of RPG Maker XP's). Suspends with a :number
    # request the owning scene answers by driving a digit-entry widget and calling
    # `resume_number` with the value, which stores it into the variable. A digit
    # count below 1 is clamped so the widget always has at least one cell.
    def do_input_number(cmd)
      digits = cmd.param(0)
      @input_digits = digits < 1 ? 1 : digits
      @input_variable = cmd.param(1)
      @wait_kind = :number
      @waiting = true
    end

    # Key Input Processing (11610): wait for — or, in no-wait mode, sample — one
    # of a chosen set of buttons and store its RPG2000 code in a variable. The
    # parameter layout matches RPG_RT and depends on the command's length:
    #   param0            target variable id
    #   param1            wait flag (0 = read this frame and continue)
    #   param2            (pre-1.50 only) accept all four arrows when non-zero
    #   param3 / param4   accept Decision (OK) / Cancel — always present
    #   param5..param9    (1.50+) accept Shift / Down / Left / Right / Up
    # The interpreter only records the request and suspends on a :key_input wait;
    # the owning scene samples real input (triggered edges when waiting, held
    # state otherwise) and calls resume_key_input with the resulting code. Number
    # and operator keys (RPG2003) and the mouse (Maniac) are not modelled.
    def do_key_input(cmd)
      var_id = cmd.param(0)
      wait = cmd.param(1) != 0
      accepted = { decision: cmd.param(3) != 0, cancel: cmd.param(4) != 0,
                   shift: false, down: false, left: false, right: false,
                   up: false }
      if cmd.parameters.size < 6
        # Pre-1.50: a single flag enables the whole D-pad, no Shift.
        if cmd.param(2) != 0
          accepted[:down] = accepted[:left] = true
          accepted[:right] = accepted[:up] = true
        end
      else
        accepted[:shift] = cmd.param(5) != 0
        accepted[:down]  = cmd.param(6) != 0
        accepted[:left]  = cmd.param(7) != 0
        accepted[:right] = cmd.param(8) != 0
        accepted[:up]    = cmd.param(9) != 0
      end
      @input_variable = var_id
      @key_input_request = { wait: wait, accepted: accepted }
      # RPG_RT clears the variable while a waiting proc is pending; a no-wait proc
      # overwrites it below via the scene's immediate resume.
      variables[var_id] = 0 if wait && var_id && var_id > 0
      @wait_kind = :key_input
      @waiting = true
    end

    # Show Inn / Stay at Inn (10730): offer to rest for a price. param0 selects
    # which term set greets the player (0 inn A, 1 inn B); param1 is the price.
    # A price of 0 skips the prompt and stays for free. The command may be
    # followed by [Stay] / [No Stay] handler branches (markers INN_STAY /
    # INN_NO_STAY, closed by INN_END) that run on the matching outcome, laid out
    # exactly like a Show Choices block. The interpreter records the request and
    # suspends on an :inn wait; the scene shows the greeting, the accept / cancel
    # choices (accept selectable only when affordable) and the gold window, then
    # resumes via resume_inn. Charging gold and healing the party happen there.
    # Enter Hero Name (10740): open the name-entry screen for the actor whose id
    # is param0. param1 is the initial character set (0 hiragana, 1 katakana,
    # 2 letters — our widget offers the letter set), param2 the "seed with the
    # current name" flag. Suspends on a :name_input wait carrying the actor id and
    # the seed name; the scene drives the entry widget and calls #resume_name_input
    # with the entered name. A no-op (no wait) for an actor not in the party, since
    # this build only instantiates party actors.
    def do_name_input(cmd)
      actor = party.actor_by_id(cmd.param(0))
      return unless actor
      @name_input_request = {
        actor_id: cmd.param(0), charset: cmd.param(1),
        seed: cmd.param(2) != 0 ? actor.name : ''
      }
      @wait_kind = :name_input
      @waiting = true
    end

    def do_show_inn(cmd)
      price = cmd.param(1)
      @inn_price = price
      @inn_indent = cmd.indent
      # Handler branches, when present, open with an INN_STAY marker immediately
      # after the command (as a Show Choices block opens with CHOICE_OPTION).
      nxt = @list[@index]
      @inn_has_handlers =
        !nxt.nil? && nxt.code == Cmd::INN_STAY && nxt.indent == cmd.indent
      @inn_request = { type: cmd.param(0), price: price,
                       can_afford: party.gold >= price, prompt: price > 0 }
      @wait_kind = :inn
      @waiting = true
    end

    # Open Shop (10720): enter a shop selling the goods listed from param4 on.
    # param0 is the mode (0 buy + sell, 1 buy only, 2 sell only); param1 the
    # shop-screen style (recorded for fidelity). Like the inn, the command may be
    # followed by [Transaction] / [No Transaction] handler branches (markers
    # SHOP_TRANSACTION / SHOP_NO_TRANSACTION, closed by SHOP_END) that run on
    # whether the player bought or sold anything. The interpreter records the
    # request and suspends on a :shop wait; the scene runs the buy / sell UI
    # (where the gold and inventory changes happen) and resumes via resume_shop.
    def do_open_shop(cmd)
      mode = cmd.param(0)
      @shop_indent = cmd.indent
      nxt = @list[@index]
      @shop_has_handlers =
        !nxt.nil? && nxt.code == Cmd::SHOP_TRANSACTION && nxt.indent == cmd.indent
      @shop_request = {
        mode: mode, allow_buy: mode == 0 || mode == 1,
        allow_sell: mode == 0 || mode == 2, type: cmd.param(1),
        goods: cmd.parameters[4..-1] || []
      }
      @wait_kind = :shop
      @waiting = true
    end

    # Enemy Encounter (10710): start a battle against a troop. param0 is the
    # troop-id source (0 constant, 1 variable) and param1 the id / variable;
    # param3 the escape mode (0 disallow, 1 end event processing on escape,
    # 2 custom [Escape] handler), param4 the defeat mode (0 game over, 1 custom
    # [Defeat] handler), param5 the first-strike flag. The command may be
    # followed by [Victory] / [Escape] / [Defeat] handler branches (markers
    # VICTORY/ESCAPE/DEFEAT_HANDLER, closed by END_BATTLE), like a Show Choices
    # block. The interpreter records the request and suspends on a :battle wait;
    # the scene runs the battle (rewards, game over) and resumes via
    # resume_battle. The turn-based battle itself is not built yet.
    def do_enemy_encounter(cmd)
      escape_mode = cmd.param(3)
      @battle_indent = cmd.indent
      @battle_escape_aborts = escape_mode == 1
      nxt = @list[@index]
      @battle_has_handlers =
        !nxt.nil? && nxt.code == Cmd::VICTORY_HANDLER && nxt.indent == cmd.indent
      @battle_request = {
        troop_id: cmd.param(0) == 0 ? cmd.param(1) : variables[cmd.param(1)],
        allow_escape: escape_mode != 0, first_strike: cmd.param(5) != 0,
        defeat_game_over: cmd.param(4) == 0
      }
      @wait_kind = :battle
      @waiting = true
    end

    # -- state commands -------------------------------------------------------

    def range(cmd)
      mode = cmd.param(0)
      a = cmd.param(1)
      b = mode == 0 ? a : cmd.param(2)
      a = variables[cmd.param(1)] if mode == 2 # indirect: id held in a variable
      b = a if mode == 2
      [a, b]
    end

    def do_control_switches(cmd)
      a, b = range(cmd)
      op = cmd.param(3) # 0 on, 1 off, 2 toggle
      (a..b).each do |id|
        case op
        when 0 then switches[id] = true
        when 1 then switches[id] = false
        when 2 then switches.flip(id)
        end
      end
    end

    def do_control_vars(cmd)
      a, b = range(cmd)
      op = cmd.param(3)  # 0 =, 1 +, 2 -, 3 *, 4 /, 5 %
      val = operand_value(cmd)
      (a..b).each { |id| variables[id] = apply(op, variables[id], val) }
    end

    def operand_value(cmd)
      case cmd.param(4) # operand type
      when 0 then cmd.param(5)                             # constant
      when 1 then variables[cmd.param(5)]                  # variable
      when 2 then variables[variables[cmd.param(5)]]       # variable indirect
      when 3 then random_operand(cmd)                      # random in a range
      when 5 then actor_operand(cmd)                       # an actor's stat
      when 7 then other_operand(cmd)                       # gold / timer / ...
      else cmd.param(5)
      end
    end

    # Operand type 3: a random integer in [param5, param6] inclusive (the bounds
    # are swapped if given the wrong way round).
    def random_operand(cmd)
      lo = cmd.param(5)
      hi = cmd.param(6)
      lo, hi = hi, lo if lo > hi
      lo + @rng.random(hi - lo + 1)
    end

    # Operand type 5: a stat of the actor with id param5. param6 selects the
    # attribute (0 level, 1 EXP, 2 HP, 3 MP, 4 max HP, 5 max MP, 6 attack,
    # 7 defence, 8 spirit, 9 agility). An actor not in the party reads as 0.
    def actor_operand(cmd)
      actor = party.actor_by_id(cmd.param(5))
      return 0 unless actor
      case cmd.param(6)
      when 0 then actor.level
      when 1 then actor.exp
      when 2 then actor.hp
      when 3 then actor.mp
      when 4 then actor.max_hp
      when 5 then actor.max_mp
      when 6 then actor.atk
      when 7 then actor.def
      when 8 then actor.int
      when 9 then actor.agi
      else 0
      end
    end

    # Operand type 7: a miscellaneous game quantity selected by param5 (0 party
    # gold, 1 timer seconds). Other selectors (steps, play time, save / battle
    # counts) are not modelled and read as 0.
    def other_operand(cmd)
      case cmd.param(5)
      when 0 then party.gold
      when 1 then @state.timer_seconds
      else 0
      end
    end

    def apply(op, cur, val)
      case op
      when 0 then val
      when 1 then cur + val
      when 2 then cur - val
      when 3 then cur * val
      when 4 then val == 0 ? cur : cur / val
      when 5 then val == 0 ? cur : cur % val
      else cur
      end
    end

    # Timer: op 0 set (seconds), 1 start, 2 stop.
    def do_timer(cmd)
      case cmd.param(0)
      when 0
        sec = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
        @state.timer_frames = sec * 60
      when 1 then @state.timer_running = true
      when 2 then @state.timer_running = false
      end
    end

    def do_change_gold(cmd)
      v = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      party.gain_gold(cmd.param(0) == 0 ? v : -v)
    end

    def do_change_items(cmd)
      item = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      amount = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
      party.gain_item(item, cmd.param(0) == 0 ? amount : -amount)
    end

    def do_change_party(cmd)
      actor = cmd.param(1) == 0 ? cmd.param(2) : variables[cmd.param(2)]
      if cmd.param(0) == 0
        party.add_actor(actor)
      else
        party.remove_actor(actor)
      end
    end

    # -- actor EXP / level ----------------------------------------------------

    # Change EXP: add (or, when the operation is "remove", subtract) an amount of
    # experience to the target actors, re-deriving each one's level and base
    # stats from the growth curve. Uses the same scope/operation/operand layout
    # as Change HP (stat_targets / stat_amount); the show-level-up-message flag is
    # ignored (no battle/message UI drives it here).
    # Change EXP: add or remove experience for the target actors, which may cross
    # one or more level thresholds. param5 is the "show message" flag — when set,
    # each level an actor gains queues a level-up message (drained by #resume).
    def do_change_exp(cmd)
      amount = stat_amount(cmd)
      show_msg = cmd.param(5) != 0
      stat_targets(cmd).each do |a|
        before = a.level
        a.gain_exp(amount)
        queue_level_up_messages(a, before, a.level) if show_msg
      end
      show_next_pending_message
    end

    # Change Level: add or subtract levels for the target actors, recomputing
    # their base stats and re-aligning EXP to the new level. Same scope/operation/
    # operand layout as Change EXP.
    # Change Level: add or remove levels for the target actors. param5 is the
    # "show message" flag — when set, each level an actor gains queues a level-up
    # message (drained by #resume).
    def do_change_level(cmd)
      amount = stat_amount(cmd)
      show_msg = cmd.param(5) != 0
      stat_targets(cmd).each do |a|
        before = a.level
        a.change_level_by(amount)
        queue_level_up_messages(a, before, a.level) if show_msg
      end
      show_next_pending_message
    end

    # Queue one level-up message per level `actor` gained going from `old_level`
    # to `new_level` (nothing when the level did not rise). RPG_RT phrases these
    # from the database terms; this build uses a plain English line for now.
    def queue_level_up_messages(actor, old_level, new_level)
      return unless new_level > old_level
      ((old_level + 1)..new_level).each do |lv|
        @pending_messages.push(["#{actor.name} is now level #{lv}!"])
      end
    end

    # Enter the next queued level-up message as a :message wait; returns false
    # (and does nothing) when the queue is empty.
    def show_next_pending_message
      return false if @pending_messages.empty?
      @message_lines = @pending_messages.shift
      @wait_kind = :message
      @waiting = true
      true
    end

    # -- actor HP / MP --------------------------------------------------------

    # The actors a stat-change command targets. param0 selects the scope: 0 the
    # whole party, 1 a fixed actor id (param1), 2 the actor whose id is held in
    # variable param1. Actors not in the party resolve to nothing.
    def stat_targets(cmd)
      case cmd.param(0)
      when 0 then party.actors
      when 1 then [party.actor_by_id(cmd.param(1))].compact
      when 2 then [party.actor_by_id(variables[cmd.param(1)])].compact
      else []
      end
    end

    # The signed amount a HP/MP change applies: param2 is the operation (0 add,
    # 1 remove) and param3/param4 the operand (0 constant / 1 variable, value).
    def stat_amount(cmd)
      amount = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
      cmd.param(2) == 0 ? amount : -amount
    end

    # Change HP: param5 is the "allow death" flag (0 floors HP at 1, 1 permits 0).
    def do_change_hp(cmd)
      amount = stat_amount(cmd)
      allow_death = cmd.param(5) != 0
      stat_targets(cmd).each { |a| a.change_hp(amount, allow_death) }
    end

    def do_change_mp(cmd)
      amount = stat_amount(cmd)
      stat_targets(cmd).each { |a| a.change_mp(amount) }
    end

    # Full recovery: restore HP and MP to their maxima for the target actors.
    def do_full_heal(cmd)
      stat_targets(cmd).each { |a| a.full_heal }
    end

    # Change Condition: inflict or cure a status condition on the target actors.
    # param0/param1 pick the targets (same scope layout as Change HP); param2 is
    # the operation (0 add / inflict, non-zero remove / cure) and param3 the state
    # id. Removing the death state (戦闘不能) revives a downed actor; inflicting it
    # knocks the actor out — the HP coupling lives in Game::Actor.
    def do_change_condition(cmd)
      state_id = cmd.param(3)
      remove = cmd.param(2) != 0
      stat_targets(cmd).each do |a|
        remove ? a.remove_state(state_id) : a.add_state(state_id)
      end
    end

    # -- actor identity / graphic ---------------------------------------------

    # Change Actor Name: rename the actor whose id is param0 to the command
    # string. A blank name is ignored (RPG_RT keeps the previous name), and an
    # actor not in the party is a no-op — this build only instantiates party
    # actors.
    def do_change_actor_name(cmd)
      name = cmd.string
      return if name.nil? || name.empty?
      actor = party.actor_by_id(cmd.param(0))
      actor.name = name if actor
    end

    # Change Actor Title: set the title (class/subtitle shown on the status
    # screen) of the actor whose id is param0 to the command string. An empty
    # string clears the title. A no-op for an actor not in the party.
    def do_change_actor_title(cmd)
      actor = party.actor_by_id(cmd.param(0))
      actor.title = cmd.string || '' if actor
    end

    # Change Sprite Association (Change Actor Graphic): give the actor whose id is
    # param0 a new CharSet graphic — the command string names the file, param1 is
    # the cell index and param2 the transparency flag (non-zero hides the sprite).
    # Records a one-shot request so the owning scene can reload the party leader's
    # on-screen sprite; a no-op for an actor not in the party.
    def do_change_actor_sprite(cmd)
      actor = party.actor_by_id(cmd.param(0))
      return unless actor
      actor.set_charset(cmd.string || '', cmd.param(1))
      actor.transparent = cmd.param(2) != 0
      @actor_graphic_changed = true
    end

    # Change Parameters: adjust a base stat. param3 selects the stat (0 max HP,
    # 1 max MP, 2 attack, 3 defence, 4 spirit/int, 5 agility), param2 is the
    # operation (0 add, 1 remove) and param4/param5 the operand (0 constant /
    # 1 variable, value).
    def do_change_params(cmd)
      type = cmd.param(3)
      amount = cmd.param(4) == 0 ? cmd.param(5) : variables[cmd.param(5)]
      amount = -amount if cmd.param(2) != 0
      stat_targets(cmd).each { |a| a.change_param(type, amount) }
    end

    # Change Equipment. param2 selects the operation: 0 equips an item (param3 0
    # = the item id in param4, 1 = the id held in variable param4) into the slot
    # matching its type; 1 removes equipment, param4 selecting the slot (0..4, or
    # 5 for every slot). Confirmed against real events, e.g. `[1, 3, 0, 0, 127]`
    # equips armour 127 onto actor 3.
    def do_change_equipment(cmd)
      targets = stat_targets(cmd)
      if cmd.param(2) == 0
        item = cmd.param(3) == 0 ? cmd.param(4) : variables[cmd.param(4)]
        targets.each { |a| a.equip_item(item) }
      else
        targets.each { |a| a.unequip(cmd.param(4)) }
      end
    end

    # -- conditional branch ---------------------------------------------------

    def do_conditional(cmd)
      return if eval_condition(cmd) # fall through into the true branch
      skip_to([Cmd::ELSE_BRANCH, Cmd::END_BRANCH], cmd.indent)
      consume # step past the else/end marker to run the else body (or continue)
    end

    def eval_condition(cmd)
      case cmd.param(0) # condition type
      when 0 # switch: param1 id, param2 state (0 on / 1 off)
        on = switches[cmd.param(1)]
        cmd.param(2) == 0 ? on : !on
      when 1 # variable: param1 id, param2 operand type, param3 operand, param4 comparison
        rhs = cmd.param(2) == 0 ? cmd.param(3) : variables[cmd.param(3)]
        compare(variables[cmd.param(1)], rhs, cmd.param(4))
      when 2 # timer: param1 seconds, param2 comparison (0 >=, 1 <=)
        cmd.param(2) == 0 ? @state.timer_seconds >= cmd.param(1) \
                          : @state.timer_seconds <= cmd.param(1)
      when 3 # gold: param1 amount, param2 comparison (0 >=, 1 <=)
        cmd.param(2) == 0 ? party.gold >= cmd.param(1) : party.gold <= cmd.param(1)
      when 4 # item: param1 id, param2 (0 has / 1 not)
        has = party.has_item?(cmd.param(1))
        cmd.param(2) == 0 ? has : !has
      when 5 # actor: param1 id, param2 sub-condition (see actor_condition)
        actor_condition(cmd)
      else true
      end
    end

    # Conditional type 5 (actor/hero): param1 is the actor id, param2 selects the
    # sub-condition — 0 in party, 1 name equals the command string, 2 level >=
    # param3, 3 HP >= param3, 4 knows skill param3, 5 has item param3 equipped,
    # 6 afflicted by state param3. The stat checks need the actor to be in the
    # party (the only actors this build instantiates); a missing actor is false.
    def actor_condition(cmd)
      id = cmd.param(1)
      return party.include_actor?(id) if cmd.param(2) == 0
      actor = party.actor_by_id(id)
      return false unless actor
      case cmd.param(2)
      when 1 then actor.name == cmd.string
      when 2 then actor.level >= cmd.param(3)
      when 3 then actor.hp >= cmd.param(3)
      when 4 then actor.knows_skill?(cmd.param(3))
      when 5 then actor.equipped?(cmd.param(3))
      when 6 then actor.state?(cmd.param(3))
      else false
      end
    end

    def compare(a, b, op)
      case op
      when 0 then a == b
      when 1 then a >= b
      when 2 then a <= b
      when 3 then a > b
      when 4 then a < b
      when 5 then a != b
      else false
      end
    end

    # -- UI / map requests ----------------------------------------------------

    def do_teleport(cmd)
      @teleport = [cmd.param(0), cmd.param(1), cmd.param(2), cmd.param(3)]
      @wait_kind = :teleport
      @waiting = true
    end

    # Memorize Location: store the player's current map id, x and y into the
    # three variables named by param0/param1/param2. Non-blocking — it only
    # records the position for a later Recall to Location.
    def do_memorize_location(cmd)
      variables[cmd.param(0)] = @state.map_id
      variables[cmd.param(1)] = @state.x
      variables[cmd.param(2)] = @state.y
    end

    # Recall to Location: teleport to the map / x / y held in the three variables
    # named by param0/param1/param2 (the counterpart to Memorize Location).
    # Routed through the same teleport request the Teleport command raises, so
    # the owning scene loads the map and moves the player; the current facing is
    # kept (direction 0).
    def do_recall_location(cmd)
      @teleport = [variables[cmd.param(0)], variables[cmd.param(1)],
                   variables[cmd.param(2)], 0]
      @wait_kind = :teleport
      @waiting = true
    end

    # Change Event Location (Set Event Location): instantly place a character on
    # the current map at a tile. param0 selects the target (10001 player, 0 /
    # 10005 this event, else a map event id); param1 the appointment mode (0 the
    # constants param2/param3, 1 the values of those two variables); param2/param3
    # the x and y. Queued as a `:set` request the scene applies — non-blocking,
    # so the rest of the command list runs on.
    def do_change_event_location(cmd)
      x = cmd.param(2)
      y = cmd.param(3)
      if cmd.param(1) == 1
        x = variables[x]
        y = variables[y]
      end
      @location_requests.push(op: :set, target: cmd.param(0), x: x, y: y)
    end

    # Trade Event Locations (Swap Event Locations): exchange the tiles of the two
    # characters named by param0 and param1 (same target ids as Change Event
    # Location). Queued as a `:swap` request the scene applies; non-blocking.
    def do_trade_event_locations(cmd)
      @location_requests.push(op: :swap, a: cmd.param(0), b: cmd.param(1))
    end

    # Store Terrain ID: write the terrain id of the tile at (x, y) into the
    # variable named by param3. Non-blocking; without a map_info hook (or on any
    # error) it stores 0.
    def do_store_terrain_id(cmd)
      x, y = query_position(cmd)
      variables[cmd.param(3)] = @map_info ? (@map_info.terrain_id(x, y) || 0) : 0
    rescue StandardError
      variables[cmd.param(3)] = 0
    end

    # Store Event ID: write the id of the event standing on the tile at (x, y)
    # into the variable named by param3 (0 when no event is there). Non-blocking.
    def do_store_event_id(cmd)
      x, y = query_position(cmd)
      variables[cmd.param(3)] = @map_info ? (@map_info.event_id_at(x, y) || 0) : 0
    rescue StandardError
      variables[cmd.param(3)] = 0
    end

    # The (x, y) tile a Store Terrain / Event ID command targets: param0 == 0
    # takes x and y as the constants param1/param2, otherwise as the values of
    # those two variables (the shared operand mode matches RPG_RT).
    def query_position(cmd)
      if cmd.param(0) == 0
        [cmd.param(1), cmd.param(2)]
      else
        [variables[cmd.param(1)], variables[cmd.param(2)]]
      end
    end

    # Move Event (Set Move Route): queue a forced move route for a target
    # character. The command parameters are [target, frequency, repeat,
    # skippable, then the move-route commands]; the target id selects the player
    # (10001), a vehicle (10002-4), this event (10005 or 0) or a map event (its
    # id). The route runs in the background, so this only records the request —
    # the scene resolves the target and steps the route (see decode_move_route).
    def do_move_event(cmd)
      params = cmd.parameters || []
      return if params.empty?
      @move_route_requests.push(
        target: cmd.param(0),
        frequency: cmd.param(1),
        repeat: cmd.param(2) != 0,
        skippable: cmd.param(3) != 0,
        commands: decode_move_route(params, cmd.string || '')
      )
    end

    # Decode the move-route commands packed into a Move Event's parameter list
    # (from index 4 on). Most ids are bare; a few carry integer parameters, and
    # change-graphic / play-sound carry a string whose bytes live in the event
    # command's string field, prefixed in the parameter list by their length
    # (matching LCF's layout). Returns Game::MoveCommand objects a MoveRoute can
    # run. String slicing assumes ASCII file names (as charset/SE names are).
    def decode_move_route(params, string)
      cmds = []
      i = 4
      soff = 0
      while i < params.size
        id = params[i]; i += 1
        a = b = c = 0
        str = ''
        case id
        when MoveCmd::SWITCH_ON, MoveCmd::SWITCH_OFF
          a = params[i] || 0; i += 1
        when MoveCmd::CHANGE_GRAPHIC
          len = params[i] || 0; i += 1
          str = string[soff, len] || ''; soff += len
          a = params[i] || 0; i += 1
        when MoveCmd::PLAY_SOUND
          len = params[i] || 0; i += 1
          str = string[soff, len] || ''; soff += len
          a = params[i] || 0; i += 1
          b = params[i] || 0; i += 1
          c = params[i] || 0; i += 1
        end
        cmds.push Game::MoveCommand.new(id, str, a, b, c)
      end
      cmds
    end

    def do_wait(cmd)
      @wait_frames = cmd.param(0) # tenths of a second in RPG2000
      @wait_kind = :wait
      @waiting = true
    end

    # Proceed With Movement: pause until every forced move route in progress (set
    # by a Move Event) has finished. The owning scene advances those routes while
    # we wait and resumes us once none remain. As in RPG_RT, a *repeating* forced
    # route never finishes, so pairing it with this command waits indefinitely.
    def do_proceed_with_movement(_cmd)
      @wait_kind = :movement
      @waiting = true
    end

    # Set Transparent Flag (Change Player Visibility): toggle whether the party
    # leader's map sprite is hidden. Non-blocking — it only records the flag on
    # the shared game state; the owning scene reads it each frame. The polarity
    # (param0 non-zero = transparent / hidden) follows EasyRPG's
    # `SetSpriteHidden(parameters[0] != 0)`; the flag persists through Save /
    # Continue.
    def do_player_visibility(cmd)
      @state.player_transparent = cmd.param(0) != 0
    end

    # Return to Title Screen: abandon the running game and go back to the title.
    # Raised as a :return_title request the owning scene answers by tearing the
    # play scenes down and showing a fresh title (there is nothing to resume, so
    # the request behaves like a one-way teleport out of the map).
    def do_return_to_title(_cmd)
      @wait_kind = :return_title
      @waiting = true
    end

    # Game Over (12520): raised as a :game_over request the owning scene answers
    # by ending the game (RPG2000 shows the Game Over screen, then the title).
    # Like Return to Title there is nothing to resume — the event stops here.
    def do_game_over(_cmd)
      @wait_kind = :game_over
      @waiting = true
    end

    # Frames per tenth of a second at RPG2000's fixed 60 fps, for turning a
    # screen effect's 0.1s-unit duration into a frame count.
    FRAMES_PER_TENTH = 6

    # Fixed length of an Erase / Show Screen transition. RPG_RT runs these for a
    # set per-style duration rather than an event-supplied one; this approximates
    # the common fade at ~0.5s.
    SCREEN_FADE_FRAMES = 32

    # Erase Screen (11010) / Show Screen (11020): fade the whole screen out to
    # black or back in over a fixed duration, using the transition style in
    # param0 (0 = fade; higher = block / stripe / scroll variants, of which only
    # the fade is modelled). Both always run their transition and pause the event
    # until it settles — the owning scene advances Game::Screen each frame and
    # resumes us on the :screen wait. Only the fade *level* is modelled; drawing
    # the black overlay is the native refinement still pending for the tint and
    # flash overlays too.
    def do_erase_screen(cmd)
      @state.screen.erase(cmd.param(0), SCREEN_FADE_FRAMES)
      return unless @state.screen.fading?
      @wait_kind = :screen
      @waiting = true
    end

    def do_show_screen(cmd)
      @state.screen.show(cmd.param(0), SCREEN_FADE_FRAMES)
      return unless @state.screen.fading?
      @wait_kind = :screen
      @waiting = true
    end

    # Tint Screen: transition the shared screen tint to the RPG2000 channels
    # param0..3 (red / green / blue / saturation, each 0..200) over param4 tenths
    # of a second. When param5 (the wait flag) is set and the transition takes
    # time, pause until it finishes — the owning scene advances Game::Screen each
    # frame and resumes us once it settles.
    def do_tint_screen(cmd)
      frames = cmd.param(4) * FRAMES_PER_TENTH
      @state.screen.tint_to(cmd.param(0), cmd.param(1), cmd.param(2),
                            cmd.param(3), frames)
      return unless cmd.param(5) != 0 && @state.screen.tinting?
      @wait_kind = :screen
      @waiting = true
    end

    # Flash Screen: flash the screen the colour param0..2 (red / green / blue) at
    # peak strength param3, fading out over param4 tenths of a second. When param5
    # (the wait flag) is set, pause until it fades — the owning scene advances
    # Game::Screen each frame and resumes us once no screen effect is animating.
    def do_flash_screen(cmd)
      frames = cmd.param(4) * FRAMES_PER_TENTH
      @state.screen.flash(cmd.param(0), cmd.param(1), cmd.param(2),
                          cmd.param(3), frames)
      return unless cmd.param(5) != 0 && @state.screen.flashing?
      @wait_kind = :screen
      @waiting = true
    end

    # Pan Screen: param0 selects the operation — 0 lock the camera in place, 1
    # unlock it (resume following the hero), 2 pan the view param2 tiles in
    # direction param1 (0 up / 1 right / 2 down / 3 left) at speed param3, 3 reset
    # the pan back to the hero at speed param3. param4 is the wait flag for the
    # pan/reset scroll (lock/unlock are instant, so they never wait).
    def do_pan_screen(cmd)
      screen = @state.screen
      case cmd.param(0)
      when 0 then screen.pan_lock
      when 1 then screen.pan_unlock
      when 2 then screen.pan(cmd.param(1), cmd.param(2), cmd.param(3))
      when 3 then screen.pan_reset(cmd.param(3))
      end
      return unless cmd.param(4) != 0 && screen.panning?
      @wait_kind = :screen
      @waiting = true
    end

    # Shake Screen: start a timed screen shake of strength param0 and speed
    # param1 for param2 tenths of a second. When param3 (the wait flag) is set,
    # pause until it finishes — the owning scene advances Game::Screen each frame
    # and resumes us once no screen effect is animating.
    def do_shake_screen(cmd)
      frames = cmd.param(2) * FRAMES_PER_TENTH
      @state.screen.shake(cmd.param(0), cmd.param(1), frames)
      return unless cmd.param(3) != 0 && @state.screen.shaking?
      @wait_kind = :screen
      @waiting = true
    end

    # Show Picture (11110): display picture param0 from the string file name at
    # the centre position param2/param3 (literal, or read from those variables
    # when the position-mode param1 is non-zero), at zoom param5 (%), transparency
    # param6 (0 opaque .. 100 clear), tone param8..11 (r/g/b/saturation) and the
    # "make colour 0 transparent" flag param7; param4 pins it to the map (it then
    # scrolls with the camera). The parameter layout is a direct port of EasyRPG
    # Player's CommandShowPicture (RPG2000 branch).
    def do_show_picture(cmd)
      id = cmd.param(0)
      return if id <= 0
      @state.show_picture(id,
                          name: picture_name(cmd),
                          x: picture_coord(cmd, 2), y: picture_coord(cmd, 3),
                          zoom: cmd.param(5),
                          opacity: trans_to_opacity(cmd.param(6)),
                          use_transparent_color: cmd.param(7) != 0,
                          fixed_to_map: cmd.param(4) > 0,
                          red: cmd.param(8), green: cmd.param(9),
                          blue: cmd.param(10), saturation: cmd.param(11))
    end

    # Move Picture (11120): ease picture param0 to a new position/zoom/opacity/
    # tone over param14 tenths of a second. When the wait flag (param15) is set,
    # pause until the move finishes — the scene advances the pictures each frame
    # and resumes us once none is moving. Same parameter layout as Show Picture,
    # plus the trailing duration/wait pair (EasyRPG's CommandMovePicture).
    def do_move_picture(cmd)
      id = cmd.param(0)
      frames = cmd.param(14) * FRAMES_PER_TENTH
      @state.move_picture(id, picture_coord(cmd, 2), picture_coord(cmd, 3),
                          cmd.param(5), trans_to_opacity(cmd.param(6)),
                          cmd.param(8), cmd.param(9), cmd.param(10),
                          cmd.param(11), frames)
      return unless cmd.param(15) != 0 && @state.pictures[id] &&
                    @state.pictures[id].moving?
      @wait_kind = :picture
      @waiting = true
    end

    # Erase Picture (11130): remove picture param0 from the screen.
    def do_erase_picture(cmd)
      @state.erase_picture(cmd.param(0))
    end

    # A picture coordinate: the literal param at `idx`, or the value of the
    # variable it names when the position-mode param (index 1) is non-zero.
    def picture_coord(cmd, idx)
      cmd.param(1) != 0 ? variables[cmd.param(idx)] : cmd.param(idx)
    end

    # RPG2000 transparency (0 opaque .. 100 fully clear) -> a 0..255 opacity.
    def trans_to_opacity(top_trans)
      (100 - Game.clamp(top_trans, 0, 100)) * 255 / 100
    end

    # The picture's file name (the command's string parameter), or ''.
    def picture_name(cmd)
      (cmd.string || '').to_s
    end

    # Weather Effects: set the map weather type (param0 — 0 none, 1 rain, 2 snow;
    # the RPG2003 additions come through as higher values) and strength (param1 —
    # 0 weak .. 2 strong) on the shared game state. Non-blocking; like the picture
    # / tint overlays this records the Ruby-half model only — compositing the
    # rain/snow particles is native renderer work still to come — but the setting
    # is applied and persists through Save / Continue.
    def do_weather(cmd)
      @state.weather.set(cmd.param(0), cmd.param(1))
    end

    # Memorize BGM: stash a copy of the currently-playing BGM so a later Play
    # Memorized BGM can restore it (e.g. duck to a fanfare, then return). Nothing
    # playing memorises nothing. Non-blocking.
    def do_memorize_bgm(_cmd)
      cur = @state.current_bgm
      @state.memorized_bgm = cur ? cur.dup : nil
    end

    # Set Teleport Target: register (or clear) a destination the party can jump
    # to with the Teleport skill. param0 is the operation (0 add, 1 remove),
    # param1 the map id; on add, param2/param3 are the tile x/y and an optional
    # switch (param4 flags its presence, param5 is the switch id) gates the
    # target's availability. Stored in a Game::State registry keyed by map id.
    # Nothing consumes it yet — the Teleport skill is not executed — so this is
    # modelled purely for save fidelity, mirroring the access flags.
    def do_set_teleport_target(cmd)
      map_id = cmd.param(1)
      if cmd.param(0) != 0
        @state.teleport_targets.delete(map_id)
        return
      end
      switch_id = cmd.param(4) != 0 ? cmd.param(5) : nil
      @state.teleport_targets[map_id] =
        { x: cmd.param(2), y: cmd.param(3), switch_id: switch_id }
    end

    # Set Escape Target: register the single destination the Escape skill jumps
    # to. param0 map id, param1/param2 the tile x/y, and an optional switch
    # (param3 flags its presence, param4 the switch id). Like the teleport
    # registry this is stored for save fidelity only; the Escape skill is not
    # executed yet.
    def do_set_escape_target(cmd)
      switch_id = cmd.param(3) != 0 ? cmd.param(4) : nil
      @state.escape_target =
        { map_id: cmd.param(0), x: cmd.param(1), y: cmd.param(2),
          switch_id: switch_id }
    end

    # Change System Graphics: override the windowskin graphic and font. The
    # command string names the System/<name> windowskin; param0 is the message
    # background stretch style (not modelled — it is not in the save) and param1
    # the font id (RPG2000 games leave it 0). Records a one-shot request so the
    # scene reloads the windowskin, and the override persists across Save /
    # Continue.
    def do_change_system_graphic(cmd)
      @state.set_system_graphic(cmd.string || '', cmd.param(1))
      @system_graphic_changed = true
    end

    # Change System BGM: override one of the system music slots (battle,
    # victory, inn, ...) selected by param0. The remaining fields carry a Music
    # struct: string = file name, param1 fade-in, param2 volume, param3 tempo,
    # param4 balance. Stashed in a Game::State slot table; the battle / inn / …
    # scenes that would play these are not built yet, so this only preserves the
    # configured music across Save / Continue.
    def do_change_system_bgm(cmd)
      @state.system_bgm[cmd.param(0)] = {
        name: cmd.string, fadein: cmd.param(1), volume: cmd.param(2),
        tempo: cmd.param(3), balance: cmd.param(4)
      }
    end

    # Change System SFX: override one of the system sound slots (cursor,
    # decision, cancel, ...) selected by param0. string = file name, param1
    # volume, param2 tempo, param3 balance. Stored for save fidelity like the
    # system BGM; nothing plays these yet.
    def do_change_system_sfx(cmd)
      @state.system_sfx[cmd.param(0)] = {
        name: cmd.string, volume: cmd.param(1),
        tempo: cmd.param(2), balance: cmd.param(3)
      }
    end

    # Play Memorized BGM: resume the BGM stashed by Memorize BGM, making it the
    # current BGM again. A no-op when nothing was memorised. Playback resumes
    # from the start — the SDL_mixer backend cannot seek to the stored position.
    def do_play_memorized_bgm(_cmd)
      bgm = @state.memorized_bgm
      return if bgm.nil? || bgm[:name].nil? || bgm[:name].empty?
      RGSS::Audio.bgm_play(bgm[:name], bgm[:volume] || 100, bgm[:tempo] || 100)
      @state.current_bgm = bgm.dup
    rescue StandardError => e
      $stderr.puts "[RPG2k] memorized BGM playback failed: #{e.message}"
      nil
    end

    def play_audio(kind, cmd)
      name = cmd.string
      return if name.nil? || name.empty?
      if kind == :bgm
        # PlayBGM parameters: [fade_in, volume, tempo, balance]. Volume/tempo
        # default to 100 when the command carries a shorter list.
        volume = cmd.parameters.size > 1 ? cmd.param(1) : 100
        pitch = cmd.parameters.size > 2 ? cmd.param(2) : 100
        # Track what is playing so Memorize BGM can stash it (RPG_RT keeps this
        # as the "current system BGM" regardless of whether playback succeeds).
        @state.current_bgm = { name: name, volume: volume, tempo: pitch }
        RGSS::Audio.bgm_play(name, volume, pitch)
      else
        # PlaySE parameters: [volume, tempo, balance].
        volume = cmd.parameters.size > 0 ? cmd.param(0) : 100
        pitch = cmd.parameters.size > 1 ? cmd.param(1) : 100
        RGSS::Audio.se_play(name, volume, pitch)
      end
    rescue StandardError => e
      $stderr.puts "[RPG2k] #{kind} playback failed for '#{name}': #{e.message}"
      nil
    end
  end
end
