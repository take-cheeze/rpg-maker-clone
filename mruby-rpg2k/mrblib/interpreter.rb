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
      CONTROL_SWITCHES = 10210
      CONTROL_VARS     = 10220
      TIMER_OPERATION  = 10230
      CHANGE_GOLD      = 10310
      CHANGE_ITEMS     = 10320
      CHANGE_PARTY     = 10330
      CHANGE_PARAM     = 10430
      CHANGE_HP        = 10460
      CHANGE_MP        = 10470
      FULL_HEAL        = 10490
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
      MOVE_EVENT       = 11330
      WAIT             = 11410
      PLAY_BGM         = 11510
      PLAY_SE          = 11550
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
      @erase_requested = false
      # Deterministic RNG for the Control Variables "random" operand (mruby has
      # no Kernel#rand here); seeded like the map scene's own RNG.
      @rng = Game::Rng.new(0x2000)
      reset_waits
    end

    def running?; @running; end
    def waiting?; @waiting; end
    attr_reader :wait_kind, :message_lines, :choice_labels, :wait_frames,
                :teleport
    # Resolves the command list a Call Event refers to (a common event, or a page
    # of a map event). Set by the owning scene; nil disables Call Event.
    attr_accessor :resolver

    def start(commands)
      @list = commands || []
      @index = 0
      @running = true
      @call_stack = []
      @move_route_requests = []
      @erase_requested = false
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

    # True (once) if an Erase Event command ran since the last call, clearing the
    # flag. The owning scene polls this after #update and removes the event that
    # was running this interpreter from the map. Like Move Event, Erase Event does
    # not pause the interpreter — the rest of the command list still runs.
    def take_erase_request
      v = @erase_requested
      @erase_requested = false
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
      reset_waits
    end

    # Abandon the rest of the current command list (e.g. after a teleport),
    # including any pending callers.
    def stop
      @running = false
      @index = @list.size
      @call_stack = []
      reset_waits
    end

    # Resume a choice, jumping into the selected option's branch.
    def choose(index)
      target = find_choice_option(index)
      @index = target if target
      reset_waits
    end

    private

    def reset_waits
      @waiting = false
      @wait_kind = nil
      @message_lines = nil
      @choice_labels = nil
      @wait_frames = 0
      @teleport = nil
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
      when Cmd::CONTROL_SWITCHES then do_control_switches cmd
      when Cmd::CONTROL_VARS     then do_control_vars cmd
      when Cmd::TIMER_OPERATION  then do_timer cmd
      when Cmd::CHANGE_GOLD      then do_change_gold cmd
      when Cmd::CHANGE_ITEMS     then do_change_items cmd
      when Cmd::CHANGE_PARTY     then do_change_party cmd
      when Cmd::CHANGE_PARAM     then do_change_params cmd
      when Cmd::CHANGE_HP        then do_change_hp cmd
      when Cmd::CHANGE_MP        then do_change_mp cmd
      when Cmd::FULL_HEAL        then do_full_heal cmd
      when Cmd::CONDITIONAL      then do_conditional cmd
      when Cmd::ELSE_BRANCH      then skip_to([Cmd::END_BRANCH], cmd.indent); consume
      when Cmd::END_BRANCH       then nil
      when Cmd::JUMP_TO_LABEL    then do_jump_label cmd
      when Cmd::LOOP             then nil # marker; body runs, END_LOOP loops back
      when Cmd::BREAK_LOOP       then do_break_loop cmd
      when Cmd::END_LOOP         then do_end_loop cmd
      when Cmd::TELEPORT         then do_teleport cmd
      when Cmd::MOVE_EVENT       then do_move_event cmd
      when Cmd::WAIT             then do_wait cmd
      when Cmd::PLAY_BGM         then play_audio(:bgm, cmd)
      when Cmd::PLAY_SE          then play_audio(:se, cmd)
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
    # attribute (0 level, 2 HP, 3 MP, 4 max HP, 5 max MP, 6 attack, 7 defence,
    # 8 spirit, 9 agility). EXP (1) is not modelled and reads as 0, as does an
    # actor not in the party.
    def actor_operand(cmd)
      actor = party.actor_by_id(cmd.param(5))
      return 0 unless actor
      case cmd.param(6)
      when 0 then actor.level
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
    # param3, 3 HP >= param3. The skill / equipment / state sub-conditions
    # (4/5/6) are not modelled and read as false. The stat checks need the actor
    # to be in the party (the only actors this build instantiates); a missing
    # actor is false.
    def actor_condition(cmd)
      id = cmd.param(1)
      return party.include_actor?(id) if cmd.param(2) == 0
      actor = party.actor_by_id(id)
      return false unless actor
      case cmd.param(2)
      when 1 then actor.name == cmd.string
      when 2 then actor.level >= cmd.param(3)
      when 3 then actor.hp >= cmd.param(3)
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

    def play_audio(kind, cmd)
      name = cmd.string
      return if name.nil? || name.empty?
      if kind == :bgm
        # PlayBGM parameters: [fade_in, volume, tempo, balance]. Volume/tempo
        # default to 100 when the command carries a shorter list.
        volume = cmd.parameters.size > 1 ? cmd.param(1) : 100
        pitch = cmd.parameters.size > 2 ? cmd.param(2) : 100
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
