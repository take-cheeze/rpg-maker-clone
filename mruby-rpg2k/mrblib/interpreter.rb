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
      SHOW_CHOICES     = 10140
      CHOICE_OPTION    = 20140
      CHOICE_END       = 20141
      CONTROL_SWITCHES = 10210
      CONTROL_VARS     = 10220
      TIMER_OPERATION  = 10230
      CHANGE_GOLD      = 10310
      CHANGE_ITEMS     = 10320
      CHANGE_PARTY     = 10330
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
      TELEPORT         = 10810
      WAIT             = 11410
      PLAY_BGM         = 11510
      PLAY_SE          = 11550
    end

    def initialize(state)
      @state = state
      @list = []
      @index = 0
      @running = false
      reset_waits
    end

    def running?; @running; end
    def waiting?; @waiting; end
    attr_reader :wait_kind, :message_lines, :choice_labels, :wait_frames,
                :teleport

    def start(commands)
      @list = commands || []
      @index = 0
      @running = true
      reset_waits
    end

    # Upper bound on commands run in a single update, so a malformed loop cannot
    # hang the game loop.
    MAX_STEPS = 1_000_000

    # Advance through commands until the list ends or a command asks to wait.
    def update
      return unless @running
      steps = 0
      while @index < @list.size && !@waiting
        cmd = @list[@index]
        @index += 1
        execute cmd
        steps += 1
        break if steps >= MAX_STEPS
      end
      @running = false if @index >= @list.size && !@waiting
    end

    # Resume after a message/wait/teleport request has been handled.
    def resume
      reset_waits
    end

    # Abandon the rest of the current command list (e.g. after a teleport).
    def stop
      @running = false
      @index = @list.size
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
      when Cmd::SHOW_CHOICES     then do_show_choices cmd
      when Cmd::CHOICE_OPTION    then skip_to([Cmd::CHOICE_END], cmd.indent); consume
      when Cmd::CHOICE_END       then nil
      when Cmd::CONTROL_SWITCHES then do_control_switches cmd
      when Cmd::CONTROL_VARS     then do_control_vars cmd
      when Cmd::TIMER_OPERATION  then do_timer cmd
      when Cmd::CHANGE_GOLD      then do_change_gold cmd
      when Cmd::CHANGE_ITEMS     then do_change_items cmd
      when Cmd::CHANGE_PARTY     then do_change_party cmd
      when Cmd::CONDITIONAL      then do_conditional cmd
      when Cmd::ELSE_BRANCH      then skip_to([Cmd::END_BRANCH], cmd.indent); consume
      when Cmd::END_BRANCH       then nil
      when Cmd::JUMP_TO_LABEL    then do_jump_label cmd
      when Cmd::LOOP             then nil # marker; body runs, END_LOOP loops back
      when Cmd::BREAK_LOOP       then do_break_loop cmd
      when Cmd::END_LOOP         then do_end_loop cmd
      when Cmd::TELEPORT         then do_teleport cmd
      when Cmd::WAIT             then do_wait cmd
      when Cmd::PLAY_BGM         then play_audio(:bgm, cmd)
      when Cmd::PLAY_SE          then play_audio(:se, cmd)
      when Cmd::END_EVENT        then @index = @list.size
      else nil # unimplemented / no-op (labels, comments, ...)
      end
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
      else cmd.param(5)
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
      when 3 # gold: param1 amount, param2 comparison (0 >=, 1 <=)
        cmd.param(2) == 0 ? party.gold >= cmd.param(1) : party.gold <= cmd.param(1)
      when 4 # item: param1 id, param2 (0 has / 1 not)
        has = party.has_item?(cmd.param(1))
        cmd.param(2) == 0 ? has : !has
      when 5 # actor in party: param1 id
        party.include_actor?(cmd.param(1))
      else true
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
    rescue StandardError
      nil
    end
  end
end
