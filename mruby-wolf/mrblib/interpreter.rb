# The WOLF RPG Editor event-command interpreter: runs the flat, indent-nested
# command lists mruby-wolf's data layer decodes (Wolf::Command, shared by map
# event pages and Common Events) against a Wolf::VarStore.
#
# Confidence notes, since none of this can be verified against genuine
# Game.exe in this engine's usual way (no wine/DxLib harness exists for WOLF
# RPG Editor yet -- see docs/adr/0064): the *framing* (one command = a count
# byte, an int32 command id, N more int32 args, an indent byte, a string
# array, an optional move-route) is proven -- the whole editor-bundled sample
# game's 27,356 Common Event commands parse with nothing left over
# (scripts/wolf_testbed_check.rb). What is reconstructed here, layered on top
# of that proven framing, is each command's *argument layout*, cross-checked
# across three independent readers (wolftrans, WolfTL, the wolfrpg-map-parser
# crate) wherever they overlap:
#
#   - VariableCondition(111)'s branch structure (a condition list, each with
#     its own ChoiceCase(401)/SpecialChoiceCase(402) marker, an optional
#     ElseCase(420)/CancelCase(421), closed by BranchEnd(499)) is
#     cross-confirmed by the crate's own byte-level parser: its four
#     "CaseType" marker signatures decode, byte-for-byte, to exactly
#     commands 401/402/420/421 in this reader's framing.
#   - SetVariable(121)'s 4-int32-argument shape (target, left, right, a
#     combined operator word) matches WolfTL's own comment on the format,
#     and the operator word's bit layout (assignment nibble, calculation
#     nibble) matches the crate's independent `Operators` struct once its
#     byte offset is translated into this reader's word-oriented view.
#   - Everything else this interpreter does not implement (StringCondition's
#     string-vs-variable comparison encoding, SetVariable's trig/random/
#     bitwise operators, Wait's exact frame semantics beyond "N frames",
#     event/hero position get-or-set) is left as an explicit, logged
#     no-op rather than a guess -- see the `unimplemented` calls below and
#     docs/TODO.md's WOLF RPG Editor section.
module Wolf
  class Interpreter
    # Mirrors WolfTL's Command.hpp CommandType enum (cross-checked against
    # wolftrans' CID_TO_CLASS and the crate's Signature enum).
    C_MESSAGE = 101
    C_CHOICES = 102
    C_COMMENT = 103
    C_FORCE_STOP_MESSAGE = 105
    C_DEBUG_MESSAGE = 106
    C_CLEAR_DEBUG_TEXT = 107
    C_VARIABLE_CONDITION = 111
    C_STRING_CONDITION = 112
    C_SET_VARIABLE = 121
    C_SET_STRING = 122
    C_TELEPORT = 130
    C_SOUND = 140
    C_PICTURE = 150
    C_START_LOOP = 170
    C_BREAK_LOOP = 171
    C_BREAK_EVENT = 172
    C_RETURN_TO_TITLE = 174
    C_END_GAME = 175
    # "ループ開始へ" (04ev_control.html: "return to the current loop's start
    # point") -- WolfTL's Command.hpp names it (confusingly) StartLoop2; the
    # wolfrpg-map-parser crate's own independent signature table names the
    # same code GotoLoopStart, matching the manual. Unlike BreakLoop it does
    # not exit the loop, it restarts it immediately (this Common Event's own
    # "メッセージウィンドウ" routine relies on exactly this: it jumps back to
    # StartLoop, skipping the rest of the iteration's body, once its
    # once-per-frame Wait has already run, rather than falling through into
    # work meant for the next display cycle).
    C_GOTO_LOOP_START = 176
    C_WAIT = 180
    C_COMMON_EVENT = 210
    C_COMMON_EVENT_RESERVE = 211
    C_SET_LABEL = 212
    C_JUMP_LABEL = 213
    C_COMMON_EVENT_BY_NAME = 300
    C_CHOICE_CASE = 401
    C_SPECIAL_CHOICE_CASE = 402
    C_ELSE_CASE = 420
    C_CANCEL_CASE = 421
    C_LOOP_END = 498
    C_BRANCH_END = 499
    BRANCH_MARKERS = [C_CHOICE_CASE, C_SPECIAL_CHOICE_CASE, C_ELSE_CASE, C_CANCEL_CASE].freeze

    # Comparison operators (common::operator in wolf-rpg-formats' Kaitai
    # spec; independently confirmed by the crate's CompareOperator enum,
    # byte-for-byte).
    OP_GT = 0
    OP_GTE = 1
    OP_EQ = 2
    OP_LTE = 3
    OP_LT = 4
    OP_NE = 5
    OP_AND = 6

    # A single common-event or map-event-page run: its own command list, its
    # own self-variable identity (for "this event" references), driven one
    # frame at a time from a Fiber so Wait can suspend without blocking
    # anything else -- the same shape mruby-rpgxp's ScriptHost driver uses
    # for the RGSS makers' own blocking main loop (ADR 0023), applied here
    # per running event instead of once globally, since several Common
    # Events (parallel ones, plus whatever they call) can be live at once.
    class Run
      def initialize(interp, commands, label = nil)
        @interp = interp
        @commands = commands
        @index = 0
        @label = label
        @done = false
        @fiber = Fiber.new { execute }
      end

      attr_reader :done

      def label; @label; end

      # Advances this run by one frame. Returns true while still running.
      def step
        return false if @done
        @fiber.resume
        !@done
      end

      private

      def execute
        while @index < @commands.size
          cmd = @commands[@index]
          @index += 1
          dispatch(cmd)
        end
      ensure
        @done = true
      end

      def dispatch(cmd)
        case cmd.code
        when Interpreter::C_SET_VARIABLE then @interp.exec_set_variable(cmd)
        when Interpreter::C_SET_STRING then @interp.exec_set_string(cmd)
        when Interpreter::C_VARIABLE_CONDITION then exec_variable_condition(cmd)
        when Interpreter::C_STRING_CONDITION
          @interp.unimplemented("StringCondition(112)")
          skip_to(cmd.indent) { |c| c.code == Interpreter::C_BRANCH_END }
        when Interpreter::C_CHOICE_CASE, Interpreter::C_SPECIAL_CHOICE_CASE,
             Interpreter::C_ELSE_CASE, Interpreter::C_CANCEL_CASE
          skip_to(cmd.indent) { |c| c.code == Interpreter::C_BRANCH_END }
        when Interpreter::C_BRANCH_END
          nil
        when Interpreter::C_START_LOOP
          nil
        when Interpreter::C_LOOP_END
          jump_to_loop_start(cmd.indent)
        when Interpreter::C_BREAK_LOOP
          # BreakLoop is nested inside the loop body (typically behind an
          # if), so it does not share the enclosing StartLoop/LoopEnd's own
          # indent the way LoopEnd itself does -- find that indent first by
          # scanning backward for the nearest StartLoop not already closed
          # by an intervening LoopEnd (bracket matching, indent-independent),
          # then skip forward to its LoopEnd exactly as BreakLoop's own
          # indent could not.
          i = enclosing_loop_start_index
          skip_to(@commands[i].indent) { |c| c.code == Interpreter::C_LOOP_END } if i
        when Interpreter::C_GOTO_LOOP_START
          # Same nested-indent situation as BreakLoop, but restart the loop
          # (jump to just past its StartLoop) instead of exiting it.
          i = enclosing_loop_start_index
          @index = i + 1 if i
        when Interpreter::C_SET_LABEL
          nil
        when Interpreter::C_JUMP_LABEL
          jump_to_label(cmd)
        when Interpreter::C_WAIT
          exec_wait(cmd)
        when Interpreter::C_COMMON_EVENT, Interpreter::C_COMMON_EVENT_RESERVE
          @interp.exec_common_event_call(cmd, reserve: cmd.code == Interpreter::C_COMMON_EVENT_RESERVE)
        when Interpreter::C_COMMON_EVENT_BY_NAME
          @interp.exec_common_event_by_name(cmd)
        when Interpreter::C_MESSAGE, Interpreter::C_COMMENT, Interpreter::C_DEBUG_MESSAGE
          @interp.exec_message(cmd)
        when Interpreter::C_CHOICES, Interpreter::C_FORCE_STOP_MESSAGE,
             Interpreter::C_CLEAR_DEBUG_TEXT, Interpreter::C_TELEPORT,
             Interpreter::C_SOUND, Interpreter::C_PICTURE,
             Interpreter::C_BREAK_EVENT, Interpreter::C_RETURN_TO_TITLE,
             Interpreter::C_END_GAME
          @interp.unimplemented(cmd.code)
        else
          @interp.unimplemented(cmd.code)
        end
      end

      # Advances @index until `block` matches a command at exactly `indent`,
      # leaving @index pointing just past it (or at the end, if none is
      # found -- a malformed branch this reader would rather run off the end
      # of than loop forever on).
      def skip_to(indent)
        while @index < @commands.size
          c = @commands[@index]
          if c.indent < indent
            return
          elsif c.indent == indent && yield(c)
            @index += 1
            return
          end
          @index += 1
        end
      end

      # VariableCondition(111): args[0] packs case_count (low nibble) and an
      # else_case flag (bit 4); each of the case_count conditions that
      # follow is 3 more int32 words (variable, value, operator). Evaluated
      # in order; the first true one wins by advancing @index to just past
      # its own ChoiceCase/SpecialChoiceCase marker (so its body, the very
      # next commands, runs by falling through normally) -- exactly
      # BranchEnd; a marker reached later during that body's own normal
      # execution (the `when *BRANCH_MARKERS` case above) then means the
      # taken body just finished, and skips past whatever cases remain.
      #
      # When no case matches and there is no ElseCase/CancelCase, the search
      # must stop at *this* construct's own BranchEnd(499) rather than keep
      # hunting for some other 401/402/420/421 marker further on: real
      # per-frame Common Events (e.g. the RPG Basic System's "メッセージ
      # ウィンドウ" loop) put ordinary top-level commands -- including a
      # Wait every loop iteration depends on to yield at all -- right after
      # that BranchEnd, at the same indent as the VariableCondition itself,
      # and those are not part of this construct's scope. Scanning past
      # BranchEnd in search of an unrelated marker skipped that Wait
      # entirely, spinning the Fiber forever with no yield (found via
      # scripts/wolf_interpreter_check.rb hanging on the real sample game).
      def exec_variable_condition(cmd)
        case_count = cmd.arg(0) & 0x0f
        conditions = Array.new(case_count) do |i|
          base = 1 + 3 * i
          [cmd.arg(base), cmd.arg(base + 1), cmd.arg(base + 2) & 0xff]
        end

        idx = 0
        loop do
          landed = nil
          skip_to(cmd.indent) do |c|
            match = Interpreter::BRANCH_MARKERS.include?(c.code) || c.code == Interpreter::C_BRANCH_END
            landed = c if match
            match
          end
          return if landed.nil? # ran off the end without even a BranchEnd (malformed); nothing left to do
          return if landed.code == Interpreter::C_BRANCH_END # no case matched; fall through normally
          if landed.code == Interpreter::C_ELSE_CASE || landed.code == Interpreter::C_CANCEL_CASE
            return # else body starts right here; let it fall through
          end
          cond = conditions[idx]
          return if cond && @interp.evaluate_condition(cond)
          idx += 1
        end
      end

      # The index of the StartLoop enclosing the BreakLoop/GotoLoopStart
      # command @index has just moved past, found by bracket-matching
      # backward: a LoopEnd met along the way belongs to an already-closed
      # nested loop, so the StartLoop that closes *it* is skipped too
      # (depth-tracked) rather than mistaken for the enclosing loop.
      def enclosing_loop_start_index
        i = @index - 2
        depth = 0
        while i >= 0
          c = @commands[i]
          if c.code == Interpreter::C_LOOP_END
            depth += 1
          elsif c.code == Interpreter::C_START_LOOP
            if depth == 0
              return i
            else
              depth -= 1
            end
          end
          i -= 1
        end
        nil
      end

      def jump_to_loop_start(indent)
        i = @index - 2 # the LoopEnd we just consumed
        while i >= 0
          c = @commands[i]
          if c.indent == indent && c.code == Interpreter::C_START_LOOP
            @index = i + 1
            return
          end
          i -= 1
        end
      end

      def jump_to_label(cmd)
        name = cmd.strings.first
        @commands.each_with_index do |c, i|
          next unless c.code == Interpreter::C_SET_LABEL && c.strings.first == name
          @index = i + 1
          return
        end
        @interp.var_store.warn_once("no-such-label-#{name}", "JumpLabel to #{name.inspect}: no matching SetLabel; ignoring")
      end

      def exec_wait(cmd)
        frames = cmd.arg(0)
        frames.times { Fiber.yield }
      end
    end

    def initialize(project, var_store)
      @project = project
      @var_store = var_store
      @common_runs = []
      @map_runs = []
      @reserved = []
      @warned = {}
    end

    attr_reader :var_store, :project

    # Every Run this interpreter starts is built through here rather than a
    # bare `Run.new` at each call site, so a caller that needs a safety net
    # against a not-yet-discovered infinite loop (scripts/wolf_interpreter_check.rb's
    # step-bounded subclass, the same soak check that already caught two real
    # hangs in Common Events) can install one for map events and confirm/
    # touch triggers too, by overriding just this one method instead of
    # duplicating #run_common_event/#start_map_event_run's own logic.
    def run_class; Run; end
    # The currently-loaded Wolf::Map, so #update can drive its events'
    # auto/parallel pages the way it already drives Common Events, and
    # #event_at/#trigger_confirm/#trigger_touch (called from WolfRPG::MapScene)
    # know which map's events to look at. Set once at map load; nothing here
    # resets @map_runs on a change, since no map transition (Teleport) is
    # implemented yet -- a future one must clear it (and reconsider
    # VarStore's per-event self-variable banks, keyed by event id alone,
    # which collide across maps that reuse small ids like 0/1/2).
    attr_accessor :current_map

    def unimplemented(what)
      var_store.warn_once("unimplemented-#{what}", "event command #{what} is not implemented yet; skipping")
    end

    def evaluate_condition(cond)
      variable, value, op = cond
      lhs = var_store.number(variable)
      rhs = var_store.number(value)
      case op
      when OP_GT then lhs > rhs
      when OP_GTE then lhs >= rhs
      when OP_EQ then lhs == rhs
      when OP_LTE then lhs <= rhs
      when OP_LT then lhs < rhs
      when OP_NE then lhs != rhs
      when OP_AND then (lhs & rhs) != 0
      else
        var_store.warn_once("cond-op-#{op}", "unknown comparison operator #{op}; treating as false")
        false
      end
    end

    # SetVariable(121): args = [target, left, right, combined_op]. The
    # combined word's low byte is an "options" bitset this reader does not
    # model yet (the manual's ±999999-clamp / real-number-calculation
    # checkboxes); byte 1's low nibble is the assignment op, high nibble the
    # calculation op that combines left/right before the assignment applies.
    # Only the operators every source agrees on are implemented; angle/sin/
    # cos/sqrt/random/bitwise ones are logged and left as a no-op rather than
    # guessed at their fixed-point scaling.
    def exec_set_variable(cmd)
      target = cmd.arg(0)
      left = var_store.number(cmd.arg(1))
      right = var_store.number(cmd.arg(2))
      op_word = cmd.arg(3)
      assign_op = (op_word >> 8) & 0xf
      calc_op = (op_word >> 12) & 0xf

      computed =
        case calc_op
        when 0x0 then left + right
        when 0x1 then left - right
        when 0x2 then left * right
        when 0x3 then right.zero? ? 0 : (left / right)
        when 0xf then right # "Nothing": use the right-hand side as-is
        else
          var_store.warn_once("calc-op-#{calc_op}", "SetVariable calculation op #{calc_op} not implemented; using the right-hand side")
          right
        end

      current = var_store.number(target)
      result =
        case assign_op
        when 0x0 then computed
        when 0x1 then current + computed
        when 0x2 then current - computed
        when 0x3 then current * computed
        when 0x4 then computed.zero? ? 0 : (current / computed)
        when 0x5 then computed.zero? ? 0 : (current % computed)
        when 0x6 then [current, computed].min
        when 0x7 then [current, computed].max
        when 0x8 then computed.abs
        else
          var_store.warn_once("assign-op-#{assign_op}", "SetVariable assignment op #{assign_op} not implemented; assigning directly")
          computed
        end

      var_store.set_number(target, fold32(result))
    end

    # Reduce to WOLF RPG's own 32-bit signed range (help/01specifi.html's
    # implicit-spec #3 documents non-optimised Variable Operation clamping at
    # roughly +-2 billion by wraparound) using the same fold-without-pack
    # trick mruby-lcf's LCF.read_ber uses, for the same 32-bit-mrb_int
    # portability reason (AGENTS.md).
    def fold32(v)
      v &= 0xffff_ffff
      v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
    end

    # SetString(122): args[0] = target (a :string / self-var / system-string
    # reference); the literal text, when there is one, is the command's own
    # first string argument. Concatenation / dynamic-content operators are
    # not modeled yet -- only plain assignment.
    def exec_set_string(cmd)
      target = cmd.arg(0)
      text = cmd.strings.first || ""
      var_store.set_string(target, text)
    end

    def exec_message(cmd)
      text = cmd.strings.first || ""
      $stderr.puts "[Wolf-MSG] #{text}" unless text.empty?
    end

    # CommonEvent(210) / CommonEventReserve(211): args = [event_id,
    # param_status, *param_numbers, (return_variable if enabled)]. Per
    # Command.hpp's call_event structure, an event_id of 500000..599999
    # addresses a Common Event (id - 500000); anything else calls a specific
    # page of a *map* event, which this reader does not drive yet.
    def exec_common_event_call(cmd, reserve:)
      event_id = cmd.arg(0)
      unless event_id >= 500_000 && event_id <= 599_999
        unimplemented("CommonEvent(210) targeting a map event page")
        return
      end
      common_id = event_id - 500_000
      status = cmd.arg(1)
      number_count = status & 0xf
      string_count = (status >> 4) & 0xf
      return_enabled = (status & 0x0100_0000) != 0
      param_numbers = Array.new(number_count) { |i| var_store.number(cmd.arg(2 + i)) }
      return_target = return_enabled ? cmd.arg(2 + number_count) : nil
      unimplemented("CommonEvent(210) string arguments") if string_count > 0
      call_common(common_id, param_numbers, return_target, reserve: reserve)
    end

    # CommonEventByName(300): looked up by name (the command's first string)
    # rather than a numeric id; same param_status/param_numbers shape.
    def exec_common_event_by_name(cmd)
      name = cmd.strings.first
      ce = project.common_events.named(name)
      unless ce
        var_store.warn_once("no-such-common-event-#{name}", "CommonEventByName #{name.inspect}: no such common event")
        return
      end
      status = cmd.arg(1)
      number_count = status & 0xf
      return_enabled = (status & 0x0100_0000) != 0
      param_numbers = Array.new(number_count) { |i| var_store.number(cmd.arg(2 + i)) }
      return_target = return_enabled ? cmd.arg(2 + number_count) : nil
      call_common(ce.id, param_numbers, return_target, reserve: false)
    end

    def call_common(common_id, param_numbers, return_target, reserve:)
      if reserve
        @reserved << [common_id, param_numbers, return_target]
        return
      end
      run_common_event(common_id, param_numbers, return_target)
    end

    # Runs one Common Event to completion (or until it Waits, in which case
    # it keeps stepping on subsequent #update calls the same way an
    # auto/parallel one does) right now, blocking the caller until it either
    # finishes or hits a Wait -- i.e. a *called* Common Event's Waits still
    # suspend only the calling event, since both share the same underlying
    # Fiber-per-Run model; the call site just runs the callee's Run inline
    # instead of registering it as one of the project's own top-level runs.
    # The first `count` numeric (non-string-quintet) self-variable slot
    # indices, in order: 0-4, then 10, 11, 12, ... -- where a Common Event's
    # own declared arguments land (help/06commonev.html's argument list maps
    # onto the same self-variable bank a CSelf reference reads).
    def numeric_self_slots(count)
      slots = []
      idx = 0
      while slots.size < count
        slots << idx unless ValueRef.common_event_self_string?(idx)
        idx += 1
      end
      slots
    end

    def run_common_event(common_id, param_numbers, return_target)
      ce = project.common_events[common_id]
      unless ce
        var_store.warn_once("no-common-event-#{common_id}", "call to common event #{common_id}, which does not exist")
        return
      end
      bank = var_store.common_event_self_bank(common_id)
      numeric_self_slots(param_numbers.size).each_with_index { |slot, k| bank[slot] = param_numbers[k] }
      with_common_event_context(common_id) do
        run = run_class.new(self, ce.commands)
        run.step while !run.done
      end
      return unless return_target
      var_store.set_number(return_target, bank[ce.return_variable] || 0)
    end

    # One frame: advances every live auto/parallel Common Event Run, starts
    # any whose run_condition just became satisfied (auto-run) or is
    # satisfied every frame (parallel), and drains reserved calls queued by
    # #call_common during the frame that queued them.
    # A simplification, not a full model of the manual's auto-vs-parallel
    # re-trigger nuance ("暗黙の仕様" #4/#5): both kinds are re-checked and
    # (re)started here the same way once their condition holds and no run
    # for them is already live, and both keep stepping every frame while
    # live. What that does not capture is an auto-run event's one-shot
    # trigger-on-the-condition-*becoming*-true semantics -- this restarts
    # one again next frame once it finishes, as long as its condition still
    # holds, rather than waiting for a fresh true edge.
    def update
      drain_reserved
      project.common_events.events.each do |ce|
        next unless ce.parallel? || ce.auto?
        next unless with_common_event_context(ce.id) { condition_met?(ce) }
        existing = @common_runs.find { |r| r[:id] == ce.id }
        if existing
          advance(existing)
        else
          start_common_run(ce)
        end
      end
      @common_runs.reject! { |r| r[:run].done }
      update_map_events
    end

    # The active page of `event`: the *last* page (in editor order) whose
    # every enabled condition holds, or nil if none do -- the same
    # last-match-wins convention mruby-rpg2k's own Game::EventPage.select
    # already uses for RPG2000/2003 map event pages (help/04eventwindowB.html
    # only documents that a page needs *all* its own conditions to hold, not
    # the cross-page precedence, so this mirrors the established sibling
    # convention rather than inventing a new one). Evaluated with "this map
    # event" set to `event.id`, since a page's own condition fields can be
    # "this event"-relative self-variable references.
    def active_page(event)
      with_map_event_context(event.id) do
        chosen = nil
        event.pages.each_with_index do |page, idx|
          chosen = [idx, page] if page_conditions_met?(page)
        end
        chosen
      end
    end

    # The [event, page] pair at map tile (x, y) with a currently-active page,
    # or nil. Used both for movement passability (an event without
    # Wolf::Page::OPT_SLIP_THROUGH blocks the tile) and to find what a touch
    # or confirm trigger should run.
    def event_at(x, y)
      return nil unless current_map
      current_map.events.each do |event|
        next unless event.x == x && event.y == y
        idx, page = active_page(event)
        return [event, page] if page
      end
      nil
    end

    # True while any *blocking* run -- an auto-run Common Event, or any map
    # event page other than a Parallel Process one -- is still executing:
    # help/04eventwindowB.html documents Auto Start as excluding other
    # (non-Parallel) events while it runs, which in practice also means the
    # hero should not be free to wander off mid-event, the same way a
    # message box would freeze movement once one exists (docs/TODO.md).
    def blocking?
      @common_runs.any? { |r| r[:blocking] && !r[:run].done } ||
        @map_runs.any? { |r| r[:blocking] && !r[:run].done }
    end

    # WolfRPG::MapScene calls this when the player presses the confirm key
    # while facing (or standing on, if Wolf::Page::OPT_SLIP_THROUGH) `event`.
    # Starts its active page's commands if it is a Confirm-trigger page and
    # not already running; returns whether `event` answers to a confirm
    # press at all (so the caller knows not to look further), regardless of
    # whether this call is what started it.
    def trigger_confirm(event)
      idx, page = active_page(event)
      return false unless page && page.trigger == Wolf::Page::TRIGGER_CONFIRM
      start_map_event_run(event, page) unless map_event_running?(event.id)
      true
    end

    # WolfRPG::MapScene calls this when the hero attempts to move onto
    # `event`'s tile. Starts its active page's commands if it is a
    # Player-Touch or Event-Touch page and not already running; returns
    # whether `event` answers to a touch attempt (the caller blocks the
    # move either way, "like a closed door" -- the same convention
    # mruby-rpg2k's own #touch_trigger?/#event_at/#start_event already
    # establish for RPG2000/2003's identical trigger pair).
    def trigger_touch(event)
      idx, page = active_page(event)
      return false unless page &&
        (page.trigger == Wolf::Page::TRIGGER_PLAYER_TOUCH || page.trigger == Wolf::Page::TRIGGER_EVENT_TOUCH)
      start_map_event_run(event, page) unless map_event_running?(event.id)
      true
    end

    private

    def page_conditions_met?(page)
      page.conditions.all? do |c|
        !c.enabled? || evaluate_condition([c.variable, c.value, c.compare_operator])
      end
    end

    # Advances every live auto/parallel map event page for #current_map the
    # same way #update already drives Common Events -- see that method's own
    # comment for the shared simplification (an Auto page restarts once it
    # finishes as long as its condition still holds, rather than waiting for
    # a fresh true edge). Player-Touch/Event-Touch/Confirm pages are never
    # started here; only #trigger_touch/#trigger_confirm do that.
    def update_map_events
      return unless current_map
      current_map.events.each do |event|
        idx, page = active_page(event)
        next unless page && (page.auto? || page.parallel?)
        existing = @map_runs.find { |r| r[:event_id] == event.id }
        if existing
          advance_map_event(existing)
        else
          start_map_event_run(event, page)
        end
      end
      @map_runs.reject! { |r| r[:run].done }
    end

    def map_event_running?(event_id)
      @map_runs.any? { |r| r[:event_id] == event_id && !r[:run].done }
    end

    def start_map_event_run(event, page)
      run = with_map_event_context(event.id) { run_class.new(self, page.commands) }
      entry = { event_id: event.id, run: run, blocking: page.trigger != Wolf::Page::TRIGGER_PARALLEL }
      @map_runs << entry
      advance_map_event(entry)
      entry
    end

    def advance_map_event(entry)
      with_map_event_context(entry[:event_id]) { entry[:run].step }
    end

    # Mirrors #with_common_event_context: needed both while a map event's
    # own commands execute and while checking its page conditions/trigger
    # (both can be "this map event self"-relative).
    def with_map_event_context(event_id)
      prev = var_store.current_map_event_id
      var_store.current_map_event_id = event_id
      yield
    ensure
      var_store.current_map_event_id = prev
    end

    def drain_reserved
      pending = @reserved
      @reserved = []
      pending.each { |common_id, params, target| run_common_event(common_id, params, target) }
    end

    # RUN_PARALLEL_ALWAYS ("常時並列") ignores the condition fields
    # entirely; every other run condition (auto-start, plain parallel) gates
    # on them, matching the byte the header packs them from (see
    # CommonEvent#initialize in data.rb): condition_variable/value default to
    # 0, and operator 0 (">")... no -- operator defaults to whatever an empty
    # condition byte decodes to, which evaluate_condition treats the same as
    # any other encoded comparison, so an all-zero condition compares 0 to 0
    # under that operator rather than needing a special case here.
    def condition_met?(ce)
      return true if ce.run_condition == Wolf::CommonEvent::RUN_PARALLEL_ALWAYS
      evaluate_condition([ce.condition_variable, ce.condition_value, ce.condition_operator])
    end

    def start_common_run(ce)
      run = with_common_event_context(ce.id) { run_class.new(self, ce.commands) }
      @common_runs << { id: ce.id, run: run, blocking: ce.auto? }
      advance(@common_runs.last)
    end

    def advance(entry)
      with_common_event_context(entry[:id]) { entry[:run].step }
    end

    # Runs `block` with var_store's "current common event" set to `common_id`
    # -- needed not just while a Run's own commands execute (so "this common
    # event self" references resolve) but also while checking an auto/
    # parallel event's own run condition, since that condition's variable/
    # value fields can themselves be "this common event self" references
    # (help/06commonev.html's auto-run condition UI reads from the same
    # self-variable bank the event's own commands would).
    def with_common_event_context(common_id)
      prev = var_store.current_common_event_id
      var_store.current_common_event_id = common_id
      yield
    ensure
      var_store.current_common_event_id = prev
    end
  end
end
