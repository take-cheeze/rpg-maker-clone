# RPG Maker XP event system: which page of an event is active, and the
# event-command interpreter that runs a page's (or common event's) command list.
#
# XP command lists are flat arrays of RPG::EventCommand (code / indent /
# parameters). Control flow is expressed by indent depth plus explicit
# terminator codes (Else 411 / branch-end 412, choice When 402/403 / end 404,
# loop repeat 413), which is cleaner to walk than the RPG2000 encoding. The
# interpreter runs synchronously until it needs the scene — a message, a choice,
# a wait or a teleport — at which point it raises `waiting?` and pauses; the
# owning Scene::Map reads the request, drives the UI and calls `resume` (or
# `choose`) to continue. A per-frame step cap keeps a pathological loop from
# hanging the game.

class RPGXP
  module Game
    # Small deterministic RNG (mruby has no seeded Kernel#rand here), used by the
    # "set variable to a random value" operand so runs are reproducible.
    class Rng
      def initialize(seed = 12_345)
        @state = seed & 0xffffffff
      end

      # A value in 0...n (n <= 0 yields 0).
      def random(n)
        return 0 if n <= 0
        @state = (@state * 1_103_515_245 + 12_345) & 0x7fffffff
        @state % n
      end
    end

    # Chooses the active page of an event: the highest-indexed page whose
    # condition is satisfied (RMXP evaluates pages top to bottom and the last
    # match wins). `self_switch_on` answers whether a given self-switch channel
    # is set for the event being evaluated.
    module EventPage
      def self.select(pages, switches, variables, self_switch_on)
        return nil unless pages
        i = pages.size - 1
        while i >= 0
          page = pages[i]
          return page if condition_met?(page && page.condition, switches,
                                        variables, self_switch_on)
          i -= 1
        end
        nil
      end

      def self.condition_met?(c, switches, variables, self_switch_on)
        return true if c.nil?
        return false if c.switch1_valid && !switches[c.switch1_id]
        return false if c.switch2_valid && !switches[c.switch2_id]
        return false if c.variable_valid &&
                        variables[c.variable_id] < c.variable_value
        return false if c.self_switch_valid && !self_switch_on.call(c.self_switch_ch)
        true
      end
    end

    # Runs one event/common-event command list against the game State.
    class Interpreter
      # Command codes (RGSS1 / RPG Maker XP).
      SHOW_TEXT       = 101
      TEXT_LINE       = 401
      SHOW_CHOICES    = 102
      WHEN            = 402
      WHEN_CANCEL     = 403
      CHOICES_END     = 404
      INPUT_NUMBER    = 103
      WAIT            = 106
      COMMENT         = 108
      COMMENT_LINE    = 408
      CONDITIONAL     = 111
      ELSE            = 411
      BRANCH_END      = 412
      LOOP            = 112
      BREAK_LOOP      = 113
      REPEAT_ABOVE    = 413
      EXIT_EVENT      = 115
      ERASE_EVENT     = 116
      CALL_COMMON     = 117
      LABEL           = 118
      JUMP_LABEL      = 119
      CONTROL_SWITCHES = 121
      CONTROL_VARS    = 122
      CONTROL_SELF_SW = 123
      CHANGE_GOLD     = 125
      CHANGE_ITEMS    = 126
      CHANGE_WEAPONS  = 127
      CHANGE_ARMOR    = 128
      CHANGE_PARTY    = 129
      TRANSFER_PLAYER = 201
      MOVE_ROUTE      = 209
      PLAY_BGM        = 241
      PLAY_BGS        = 245
      PLAY_ME         = 249
      PLAY_SE         = 250
      BATTLE_PROCESS  = 301

      # Battle Processing (301) result branches, at the 301's own indent: If Win
      # (601), If Escape (602), If Lose (603) and the branch terminator (604).
      IF_WIN     = 601
      IF_ESCAPE  = 602
      IF_LOSE    = 603
      BATTLE_END = 604

      MAX_STEPS_PER_FRAME = 10_000
      MAX_CALL_DEPTH = 100

      # Set Move Route (209) target codes: RMXP stores -1 for the player and 0 for
      # "this event"; a positive value is a map event id.
      MOVE_TARGET_PLAYER = -1
      MOVE_TARGET_THIS   = 0

      def initialize(state)
        @state = state
        @rng = Rng.new
        @resolver = nil
        @battle_outcome = :win
        reset
      end

      # resolver#common_event_list(id) -> the command list of a common event.
      attr_accessor :resolver
      # The result a Battle Processing (301) command resolves to while there is
      # no battle system: :win (default, so the victory branch runs and the game
      # progresses), :escape or :lose. A future battle scene sets this from the
      # real outcome before the interpreter navigates the result branches.
      attr_accessor :battle_outcome
      attr_reader :wait_kind, :message_lines, :choice_labels, :choice_cancel,
                  :wait_frames, :teleport, :input_variable, :input_digits

      def running?; @running; end
      def waiting?; @waiting; end

      # Begin running `list` as the given event on `map_id` (nil event_id for a
      # common event with no self-switch context).
      def start(list, map_id = nil, event_id = nil)
        @list = list || []
        @index = 0
        @map_id = map_id
        @event_id = event_id
        @call_stack = []
        @move_route_requests = []
        @erase_requested = false
        @running = true
        reset_waits
        self
      end

      def stop
        @list = []
        @index = 0
        @call_stack = []
        @move_route_requests = []
        @running = false
        reset_waits
      end

      # True (once) if an Erase Event command ran since the last call, clearing
      # the flag. The scene polls this after #update and removes the running
      # event from the map (Erase Event does not pause the interpreter — the rest
      # of the list still runs).
      def take_erase_request
        v = @erase_requested
        @erase_requested = false
        v
      end

      # Drain the Set Move Route (209) requests queued since the last call,
      # returning them (each a hash: target -> :player or an event id, route ->
      # the RPG::MoveRoute) and clearing the queue. Unlike a message / wait /
      # teleport, a Move Route does not suspend the interpreter — the route runs
      # in the background — so the owning Scene::Map polls this after each #update
      # and applies the routes to the target characters.
      def take_move_route_requests
        reqs = @move_route_requests || []
        @move_route_requests = []
        reqs
      end

      # Advance until the list finishes or a UI request suspends us. Runs at most
      # MAX_STEPS_PER_FRAME commands so a bad loop cannot hang the frame.
      def update
        return unless @running
        return if @waiting
        steps = 0
        while @running && !@waiting
          if @index >= @list.size
            break unless return_from_call
            next
          end
          execute(@list[@index])
          steps += 1
          if steps >= MAX_STEPS_PER_FRAME
            $stderr.puts "[RGSS] interpreter step cap hit; stopping event"
            stop
            break
          end
        end
        @running = false if !@waiting && @index >= @list.size && @call_stack.empty?
      end

      # Resume after a plain message / wait / teleport request.
      def resume
        reset_waits
        update
      end

      # Resume an Input Number request: store the entered `value` into the target
      # variable and continue running the list.
      def resume_number(value)
        variables[@input_variable] = value.to_i if @input_variable
        reset_waits
        update
      end

      # Resume a choice: `index` is the chosen option (or the cancel index).
      def choose(index)
        list = @list
        base_indent = @choice_indent
        reset_waits
        target = find_when(list, @choice_start, base_indent, index)
        @index = target ? target + 1 : skip_choices_end(list, @choice_start, base_indent)
        update
      end

      private

      def reset
        @list = []
        @index = 0
        @running = false
        @call_stack = []
        @move_route_requests = []
        @erase_requested = false
        reset_waits
      end

      def reset_waits
        @waiting = false
        @wait_kind = nil
        @message_lines = nil
        @choice_labels = nil
        @choice_cancel = nil
        @wait_frames = 0
        @teleport = nil
        @input_variable = nil
        @input_digits = nil
      end

      def switches;  @state.switches;  end
      def variables; @state.variables; end

      def execute(cmd)
        case cmd.code
        when SHOW_TEXT       then do_show_text(cmd)
        when SHOW_CHOICES    then do_show_choices(cmd)
        when INPUT_NUMBER    then do_input_number(cmd)
        when WHEN, WHEN_CANCEL then skip_past_choices(cmd) # fell through a branch
        when CHOICES_END, BRANCH_END, LABEL, COMMENT, COMMENT_LINE,
             TEXT_LINE, 0
          consume
        when WAIT            then do_wait(cmd)
        when CONDITIONAL     then do_conditional(cmd)
        when ELSE            then skip_to_after([BRANCH_END], cmd.indent) # true branch fell through
        when LOOP            then consume
        when REPEAT_ABOVE    then do_repeat(cmd)
        when BREAK_LOOP      then do_break(cmd)
        when EXIT_EVENT      then stop
        when ERASE_EVENT     then do_erase_event(cmd)
        when CALL_COMMON     then do_call_common(cmd)
        when JUMP_LABEL      then do_jump_label(cmd)
        when CONTROL_SWITCHES then do_control_switches(cmd)
        when CONTROL_VARS    then do_control_vars(cmd)
        when CONTROL_SELF_SW then do_control_self_switch(cmd)
        when CHANGE_GOLD     then do_change_gold(cmd)
        when CHANGE_ITEMS    then do_change_items(cmd)
        when CHANGE_WEAPONS  then do_change_weapons(cmd)
        when CHANGE_ARMOR    then do_change_armor(cmd)
        when CHANGE_PARTY    then do_change_party(cmd)
        when TRANSFER_PLAYER then do_transfer(cmd)
        when MOVE_ROUTE      then do_move_route(cmd)
        when BATTLE_PROCESS  then do_battle_process(cmd)
        when IF_WIN, IF_ESCAPE, IF_LOSE then skip_past_battle(cmd) # fell through a branch
        when BATTLE_END      then consume
        when PLAY_BGM        then do_play(cmd, :bgm)
        when PLAY_BGS        then do_play(cmd, :bgs)
        when PLAY_ME         then do_play(cmd, :me)
        when PLAY_SE         then do_play(cmd, :se)
        else consume # unsupported command: skip
        end
      end

      def consume
        @index += 1
      end

      def param(cmd, i, default = nil)
        v = cmd.parameters && cmd.parameters[i]
        v.nil? ? default : v
      end

      # -- flow helpers -------------------------------------------------------

      # Advance @index just past the first command at `indent` whose code is in
      # `codes`, starting from @index.
      def skip_to_after(codes, indent)
        i = @index + 1
        while i < @list.size
          c = @list[i]
          return (@index = i + 1) if c.indent == indent && codes.include?(c.code)
          i += 1
        end
        @index = @list.size
      end

      # Set @index to the first command at `indent` whose code is in `codes`
      # (without stepping past it); returns that index or nil.
      def seek(codes, indent, from)
        i = from
        while i < @list.size
          c = @list[i]
          return i if c.indent == indent && codes.include?(c.code)
          i += 1
        end
        nil
      end

      # -- messages / choices -------------------------------------------------

      def do_show_text(cmd)
        lines = []
        first = param(cmd, 0)
        lines << first.to_s if first.is_a?(String)
        # Following 401 lines belong to the same text box.
        j = @index + 1
        while j < @list.size && @list[j].code == TEXT_LINE
          lines << param(@list[j], 0).to_s
          j += 1
        end
        @index = j
        @message_lines = lines.empty? ? [""] : lines
        @wait_kind = :message
        @waiting = true
      end

      def do_show_choices(cmd)
        @choice_labels = (param(cmd, 0) || []).map(&:to_s)
        @choice_cancel = param(cmd, 1, 0)
        @choice_start = @index
        @choice_indent = cmd.indent
        @wait_kind = :choice
        @waiting = true
      end

      # The 402/403 matching the chosen option, searched at the choices' indent.
      def find_when(list, choice_start, indent, chosen)
        i = choice_start + 1
        while i < list.size
          c = list[i]
          if c.indent == indent
            return i if c.code == WHEN && c.parameters[0] == chosen
            return i if c.code == WHEN_CANCEL && chosen == @choice_cancel
            break if c.code == CHOICES_END
          end
          i += 1
        end
        nil
      end

      def skip_choices_end(list, choice_start, indent)
        i = choice_start + 1
        while i < list.size
          c = list[i]
          return i + 1 if c.indent == indent && c.code == CHOICES_END
          i += 1
        end
        list.size
      end

      # A When/WhenCancel reached by falling through the previous branch: jump to
      # just past the choice block's 404.
      def skip_past_choices(cmd)
        skip_to_after([CHOICES_END], cmd.indent)
      end

      # -- battle processing --------------------------------------------------

      # Battle Processing (301): [troop_id, can_escape, can_lose]. There is no
      # battle system yet, so resolve the fight to @battle_outcome (a win by
      # default, so the common victory branch runs and the game progresses) and
      # jump into the matching result branch — If Win (601) / If Escape (602) /
      # If Lose (603) — skipping the others. The 601/602/603 markers sit at the
      # 301's own indent, like a choice's When markers, terminated by 604. The
      # stub is logged so a skipped battle is visible rather than silent.
      def do_battle_process(cmd)
        troop_id = param(cmd, 0)
        code = case @battle_outcome
               when :escape then IF_ESCAPE
               when :lose   then IF_LOSE
               else IF_WIN
               end
        $stderr.puts "[RGSS] Battle Processing (troop #{troop_id.inspect}) " \
                     "not implemented; resolving as #{@battle_outcome}"
        target = seek_battle_branch([code], cmd.indent, @index + 1)
        @index = target ? target + 1 : skip_to_battle_end(cmd.indent)
      end

      # A branch marker reached by falling through the previous branch's body:
      # jump to just past the block's 604.
      def skip_past_battle(cmd)
        skip_to_after([BATTLE_END], cmd.indent)
      end

      # First command at `indent` whose code is in `codes`, searched from `from`
      # and bounded by the block terminator (604); nil if none precedes it.
      def seek_battle_branch(codes, indent, from)
        i = from
        while i < @list.size
          c = @list[i]
          if c.indent == indent
            return i if codes.include?(c.code)
            break if c.code == BATTLE_END
          end
          i += 1
        end
        nil
      end

      # Index just past the block's 604 at `indent` (or the list end).
      def skip_to_battle_end(indent)
        i = @index + 1
        while i < @list.size
          c = @list[i]
          return i + 1 if c.indent == indent && c.code == BATTLE_END
          i += 1
        end
        @list.size
      end

      # Input Number (103): [variable_id, digits]. Suspends with a :number request
      # the scene answers by driving a digit-entry widget and calling
      # `resume_number` with the value, which stores it into the variable.
      def do_input_number(cmd)
        @input_variable = param(cmd, 0)
        digits = param(cmd, 1, 1).to_i
        @input_digits = digits < 1 ? 1 : digits
        @wait_kind = :number
        @waiting = true
        @index += 1
      end

      def do_wait(cmd)
        @wait_frames = param(cmd, 0, 0).to_i * 2 # RGSS wait unit is 2 frames
        @wait_kind = :wait
        @waiting = true
        @index += 1
      end

      # -- conditionals -------------------------------------------------------

      def do_conditional(cmd)
        if eval_condition(cmd)
          @index += 1 # enter the true branch body
        else
          # Skip to Else or branch-End at this indent; step past it. When we land
          # on Else, execution continues into the else body.
          target = seek([ELSE, BRANCH_END], cmd.indent, @index + 1)
          @index = target ? target + 1 : @list.size
        end
      end

      def eval_condition(cmd)
        case param(cmd, 0)
        when 0 # switch: [0, id, value(0 on / 1 off)]
          switches[param(cmd, 1)] == (param(cmd, 2) == 0)
        when 1 # variable: [1, id, cmp_type(0 const/1 var), operand, operator]
          lhs = variables[param(cmd, 1)]
          rhs = param(cmd, 2) == 0 ? param(cmd, 3) : variables[param(cmd, 3)]
          compare(lhs, rhs, param(cmd, 4, 0))
        when 2 # self switch: [2, ch, value(0 on / 1 off)]
          self_switch_on?(param(cmd, 1)) == (param(cmd, 2) == 0)
        when 4 # actor: [4, actor_id, sub_type, ...]; sub 0 = "is in the party"
          if param(cmd, 2) == 0
            @state.party.include?(param(cmd, 1))
          else
            true # name / skill / equipment / state sub-conditions not modelled
          end
        when 7 # gold: [7, amount, cmp(0 >= / 1 <=)]
          param(cmd, 2) == 0 ? @state.gold >= param(cmd, 1) : @state.gold <= param(cmd, 1)
        when 8 # item: [8, item_id] — party holds at least one
          @state.item_count(param(cmd, 1)) > 0
        when 9 # weapon: [9, weapon_id, include_equipped?] — party holds it
          @state.weapon_count(param(cmd, 1)) > 0
        when 10 # armor: [10, armor_id, include_equipped?] — party holds it
          @state.armor_count(param(cmd, 1)) > 0
        else
          true # unsupported condition types default to the true branch
        end
      end

      def compare(lhs, rhs, op)
        case op
        when 0 then lhs == rhs
        when 1 then lhs >= rhs
        when 2 then lhs <= rhs
        when 3 then lhs > rhs
        when 4 then lhs < rhs
        when 5 then lhs != rhs
        else lhs == rhs
        end
      end

      # -- loops --------------------------------------------------------------

      def do_repeat(cmd)
        # Jump back to the matching Loop (112) at this indent.
        i = @index - 1
        while i >= 0
          c = @list[i]
          return (@index = i + 1) if c.indent == cmd.indent && c.code == LOOP
          i -= 1
        end
        @index += 1
      end

      def do_break(cmd)
        # Break out to just past the enclosing loop's Repeat (413): the first 413
        # ahead at a shallower indent than this Break (a break may be nested in
        # conditionals inside the loop, so its own indent is not the loop's).
        i = @index + 1
        while i < @list.size
          c = @list[i]
          return (@index = i + 1) if c.code == REPEAT_ABOVE && c.indent < cmd.indent
          i += 1
        end
        @index = @list.size
      end

      # -- labels / calls -----------------------------------------------------

      def do_jump_label(cmd)
        name = param(cmd, 0)
        i = 0
        while i < @list.size
          c = @list[i]
          return (@index = i) if c.code == LABEL && c.parameters[0] == name
          i += 1
        end
        @index += 1
      end

      def do_call_common(cmd)
        id = param(cmd, 0)
        list = @resolver && @resolver.common_event_list(id)
        @index += 1
        return unless list && !list.empty?
        if @call_stack.size >= MAX_CALL_DEPTH
          $stderr.puts "[RGSS] common-event call depth exceeded; skipping"
          return
        end
        @call_stack.push([@list, @index, @event_id])
        @list = list
        @index = 0
        # A called common event keeps the caller's self-switch/event context.
      end

      def return_from_call
        return false if @call_stack.empty?
        @list, @index, @event_id = @call_stack.pop
        true
      end

      # Erase Event (116): flag the running event for removal and keep going —
      # RMXP erases the event (hides it, drops its triggers) but the current
      # command list runs to the end.
      def do_erase_event(cmd)
        @erase_requested = true if @event_id
        @index += 1
      end

      # -- state changes ------------------------------------------------------

      def do_control_switches(cmd)
        first = param(cmd, 0)
        last = param(cmd, 1, first)
        on = param(cmd, 2) == 0
        (first..last).each { |id| switches[id] = on }
        @index += 1
      end

      def do_control_vars(cmd)
        first = param(cmd, 0)
        last = param(cmd, 1, first)
        op = param(cmd, 2, 0)
        val = var_operand(cmd)
        (first..last).each do |id|
          variables[id] = apply_op(op, variables[id], val)
        end
        @index += 1
      end

      def var_operand(cmd)
        case param(cmd, 3)
        when 0 then param(cmd, 4, 0)                    # constant
        when 1 then variables[param(cmd, 4)]           # variable
        when 2 # random: [.., 2, min, max]
          lo = param(cmd, 4, 0)
          hi = param(cmd, 5, lo)
          lo + @rng.random(hi - lo + 1)
        when 3 then @state.item_count(param(cmd, 4)) # item count held
        when 7 then game_quantity(param(cmd, 4))     # "other" game data
        else 0                                          # unsupported operand
        end
      end

      # Control Variables "other" operand (type 7): a handful of game quantities.
      # Only the display-independent ones are modelled; the rest read as 0.
      def game_quantity(kind)
        case kind
        when 0 then @state.map_id      # map id
        when 1 then @state.party.size  # party member count
        when 2 then @state.gold        # gold
        else 0                         # steps / play time / timer / saves / battles
        end
      end

      def apply_op(op, cur, val)
        case op
        when 0 then val
        when 1 then cur + val
        when 2 then cur - val
        when 3 then cur * val
        when 4 then val == 0 ? cur : cur / val
        when 5 then val == 0 ? cur : cur % val
        else val
        end
      end

      def do_control_self_switch(cmd)
        ch = param(cmd, 0)
        on = param(cmd, 1) == 0
        @state.set_self_switch(@map_id, @event_id, ch, on) if @event_id
        @index += 1
      end

      def do_change_gold(cmd)
        amount = param(cmd, 1) == 0 ? param(cmd, 2, 0) : variables[param(cmd, 2)]
        @state.gold += (param(cmd, 0) == 0 ? amount : -amount)
        @state.gold = 0 if @state.gold < 0
        @index += 1
      end

      # Change Items / Weapons / Armor (126/127/128):
      # [id, operation(0 increase / 1 decrease), operand(0 const / 1 variable),
      #  amount]. A variable operand reads the count from that variable.
      def do_change_items(cmd);   change_possession(cmd) { |id, n| @state.gain_item(id, n) };   end
      def do_change_weapons(cmd); change_possession(cmd) { |id, n| @state.gain_weapon(id, n) }; end
      def do_change_armor(cmd);   change_possession(cmd) { |id, n| @state.gain_armor(id, n) };  end

      def change_possession(cmd)
        id = param(cmd, 0)
        amount = param(cmd, 2) == 0 ? param(cmd, 3, 0) : variables[param(cmd, 3)]
        amount = -amount if param(cmd, 1) != 0 # decrease
        yield(id, amount)
        @index += 1
      end

      # Change Party Member (129): [actor_id, operation(0 add / 1 remove),
      # initialize?]. Adds an actor to the party (no duplicates, appended in the
      # order added) or removes it. The `initialize` flag (reset stats on add) is
      # ignored until actor battle stats are modelled.
      def do_change_party(cmd)
        actor_id = param(cmd, 0)
        if param(cmd, 1) == 0
          @state.party << actor_id unless @state.party.include?(actor_id)
        else
          @state.party.delete(actor_id)
        end
        @index += 1
      end

      def do_transfer(cmd)
        if param(cmd, 0) == 0 # direct designation
          map_id = param(cmd, 1)
          x = param(cmd, 2)
          y = param(cmd, 3)
        else # variable designation
          map_id = variables[param(cmd, 1)]
          x = variables[param(cmd, 2)]
          y = variables[param(cmd, 3)]
        end
        @teleport = [map_id, x, y, param(cmd, 4, 0)]
        @wait_kind = :teleport
        @waiting = true
        @index += 1
      end

      # Set Move Route (209): [target, RPG::MoveRoute]. Queues a forced route for
      # the target (the player, this event, or a map event id) without pausing —
      # the scene drains the queue and drives the route in the background. A route
      # aimed at "this event" from a common event with no event context, or with
      # no route object, is dropped.
      def do_move_route(cmd)
        target = param(cmd, 0)
        route = param(cmd, 1)
        @index += 1
        return unless route
        resolved =
          case target
          when MOVE_TARGET_PLAYER then :player
          when MOVE_TARGET_THIS   then @event_id
          else target
          end
        return if resolved.nil?
        @move_route_requests << { target: resolved, route: route }
      end

      def do_play(cmd, kind)
        audio = param(cmd, 0)
        return @index += 1 unless audio && audio.respond_to?(:name) && audio.name
        name = audio.name
        vol = audio.respond_to?(:volume) ? (audio.volume || 100) : 100
        pit = audio.respond_to?(:pitch) ? (audio.pitch || 100) : 100
        begin
          case kind
          when :bgm then Audio.bgm_play(name, vol, pit)
          when :bgs then Audio.bgs_play(name, vol, pit)
          when :me  then Audio.me_play(name, vol, pit)
          when :se  then Audio.se_play(name, vol, pit)
          end
        rescue StandardError => e
          $stderr.puts "[RGSS] event audio '#{name}' failed: #{e.message}"
        end
        @index += 1
      end

      def self_switch_on?(ch)
        return false unless @event_id
        @state.self_switch(@map_id, @event_id, ch)
      end
    end
  end
end
