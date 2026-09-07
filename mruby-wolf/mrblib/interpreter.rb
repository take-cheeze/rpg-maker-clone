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
    # WolfTL's own "Blank": a deliberately empty command row (the editor
    # leaves one behind for a deleted command, or a user adds one purely
    # for indentation/spacing) -- always zero args/strings in every one of
    # its 3468 real occurrences, the single most common command code in
    # the sample game. A genuine no-op, not missing functionality, so it
    # skips #unimplemented's own "not implemented yet" log entirely.
    C_BLANK = 0
    C_MESSAGE = 101
    C_CHOICES = 102
    # Choices(102)'s own "キャンセル時の分岐先" (cancel-key destination) field,
    # cross-confirmed against the wolfrpg-map-parser crate's own independent
    # `CancelCase` enum: 0 a dedicated CancelCase(421) branch follows the
    # choice cases ("別分岐"), 1 the cancel key does nothing at all
    # ("キャンセル不能"), anything else (2+) means "act as if choice N-2 was
    # picked" -- no separate branch marker for that last one.
    CHOICE_CANCEL_SEPARATE = 0
    CHOICE_CANCEL_DISABLED = 1
    C_COMMENT = 103
    C_FORCE_STOP_MESSAGE = 105
    C_DEBUG_MESSAGE = 106
    C_CLEAR_DEBUG_TEXT = 107
    C_VARIABLE_CONDITION = 111
    C_STRING_CONDITION = 112
    C_SET_VARIABLE = 121
    C_SET_STRING = 122
    # "その他2" tab's "■変数操作+" button (help/04ev_valuenext.html;
    # WolfTL's own Command.hpp names it SetVariableEx, the wolfrpg-map-
    # parser crate's own SetVariablePlusCommand). A much larger command
    # than SetVariable(121) -- dozens of "character state"/"position"/
    # "picture"/"other" queries -- see #exec_set_variable_ex's own comment
    # for what is cross-confirmed and implemented versus not.
    C_SET_VARIABLE_EX = 124
    C_INPUT_KEY = 123
    C_TELEPORT = 130
    C_SOUND = 140
    C_PICTURE = 150
    # "その他1" tab's "■動作指定" button (help/04ev_movesettingB.html: "イベン
    # トコマンド「その他1」にて、「■動作指定」ボタンを押したとき" is one of the
    # two places a move route is authored, the other being a page's own
    # "カスタム" route). Confirmed empirically: every real command whose
    # generic framing parsed a trailing move-route block (`Command#route?`)
    # carries this code, in both Common Events and map event pages.
    # "その他2" tab's "■ＤＢ操作" button (help/04ev_db.html; WolfTL's own
    # Command.hpp names it Database, the wolfrpg-map-parser crate's own
    # `db_management_command`). See #exec_database's own comment for what
    # this reader implements versus the manual's much larger documented
    # surface (XY配列, name<->index lookups, insert/extract/copy/sort,
    # CSV import/export).
    C_DATABASE = 250
    C_SET_MOVE_ROUTE = 201
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
    # "回数付きループ" (04ev_control.html): the same LoopEnd(498) terminator
    # StartLoop(170) uses, but bounded to a real (possibly variable-held)
    # iteration count rather than running until BreakLoop -- WolfTL's own
    # Command.hpp confirms it shares LoopEnd with StartLoop (there is only
    # one LoopEnd code). The manual documents 0 (or fewer) iterations as
    # never running the body at all, and a JumpLabel(213) landing inside a
    # LoopTimes body *from outside it* as running exactly once regardless
    # of the configured count (its own remaining-count tracking, keyed by
    # this loop's own StartLoop-equivalent position, was never initialized
    # by that jump) -- both handled by #exec_loop_times/#continue_loop.
    C_LOOP_TIMES = 179
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
        # LoopTimes(179)'s own remaining-iteration count, keyed by that
        # command's own @commands index -- see #exec_loop_times/
        # #continue_loop. A plain Hash rather than per-command state on
        # Command itself, since the same physical LoopTimes line can be
        # "active" with a different remaining count each time an outer loop
        # wraps around and re-enters it.
        @loop_counters = {}
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
        when Interpreter::C_BLANK
          nil
        when Interpreter::C_SET_VARIABLE then @interp.exec_set_variable(cmd)
        when Interpreter::C_SET_VARIABLE_EX then @interp.exec_set_variable_ex(cmd)
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
        when Interpreter::C_LOOP_TIMES
          exec_loop_times(cmd)
        when Interpreter::C_LOOP_END
          i = find_loop_start(cmd.indent)
          continue_loop(i, from_loop_end: true) if i
        when Interpreter::C_BREAK_LOOP
          # BreakLoop is nested inside the loop body (typically behind an
          # if), so it does not share the enclosing StartLoop/LoopEnd's own
          # indent the way LoopEnd itself does -- find that indent first by
          # scanning backward for the nearest StartLoop/LoopTimes not
          # already closed by an intervening LoopEnd (bracket matching,
          # indent-independent), then skip forward to its LoopEnd exactly
          # as BreakLoop's own indent could not.
          i = enclosing_loop_start_index
          if i
            @loop_counters.delete(i)
            skip_to(@commands[i].indent) { |c| c.code == Interpreter::C_LOOP_END }
          end
        when Interpreter::C_GOTO_LOOP_START
          # Same nested-indent situation as BreakLoop, but restart the loop
          # (or, for a LoopTimes loop, consume one iteration exactly like
          # reaching LoopEnd would -- 04ev_control.html's own wording
          # treats "return to the loop's start" as ending the current
          # iteration early, not skipping the count) instead of exiting it.
          i = enclosing_loop_start_index
          continue_loop(i, from_loop_end: false) if i
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
        when Interpreter::C_PICTURE
          @interp.exec_picture(cmd)
        when Interpreter::C_SET_MOVE_ROUTE
          @interp.exec_set_move_route(cmd)
        when Interpreter::C_CHOICES
          exec_choices(cmd)
        when Interpreter::C_SOUND
          @interp.exec_sound(cmd)
        when Interpreter::C_INPUT_KEY
          exec_input_key(cmd)
        when Interpreter::C_DATABASE
          @interp.exec_database(cmd)
        when Interpreter::C_FORCE_STOP_MESSAGE,
             Interpreter::C_CLEAR_DEBUG_TEXT, Interpreter::C_TELEPORT,
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
        select_branch(cmd.indent) { |idx| conditions[idx] && @interp.evaluate_condition(conditions[idx]) }
      end

      # Shared by VariableCondition(111) and Choices(102): both compile down
      # to the same flat branch-marker shape (some number of ChoiceCase/
      # SpecialChoiceCase markers in source order, an optional trailing
      # ElseCase/CancelCase, closed by BranchEnd(499)) -- confirmed for
      # Choices by dumping real map-event Choices commands from the sample
      # game and walking what follows them by hand: a two-choice Choices
      # carries exactly two ChoiceCase markers (in source order, one per
      # configured choice slot) and, only when its own "cancel behaviour" is
      # the documented "別分岐" [separate branch] option, one trailing
      # CancelCase -- otherwise none, matching the manual's own
      # help/04ev_movesettingB.html-adjacent 04ev_select.html description of
      # a "same as choosing option N" cancel not needing its own branch.
      #
      # `matcher` is called with each ChoiceCase/SpecialChoiceCase's own
      # 0-based *encounter order*, not its own numeric argument -- real
      # command dumps show that argument does not track selection order at
      # all (a two-choice Choices' own two ChoiceCase markers carry
      # `args=[2]`/`args=[3]` in one example, `args=[2]`/`args=[3]` again in
      # a completely differently-shaped one; VariableCondition's own
      # ChoiceCase/SpecialChoiceCase markers already ignored this argument
      # for the same reason before this method existed).
      #
      # Stops (leaving @index just past whatever it landed on, so that
      # marker's own body runs next by falling through normally) the first
      # time `matcher` returns true for a ChoiceCase/SpecialChoiceCase, or
      # immediately upon reaching an ElseCase/CancelCase (its body always
      # runs when reached this way -- the caller decides whether to walk
      # into one at all, e.g. Choices only reaches this when the player
      # actually canceled). Falls through past the whole construct (no
      # `skip_to` match at all) on BranchEnd or a malformed/missing one.
      def select_branch(indent)
        idx = 0
        loop do
          landed = nil
          skip_to(indent) do |c|
            match = Interpreter::BRANCH_MARKERS.include?(c.code) || c.code == Interpreter::C_BRANCH_END
            landed = c if match
            match
          end
          return if landed.nil? # ran off the end without even a BranchEnd (malformed); nothing left to do
          return if landed.code == Interpreter::C_BRANCH_END # no case matched; fall through normally
          if landed.code == Interpreter::C_ELSE_CASE || landed.code == Interpreter::C_CANCEL_CASE
            return # this body starts right here; let it fall through
          end
          return if yield(idx)
          idx += 1
        end
      end

      # Choices(102): args[0] packs the choice count (low nibble), the
      # "cancel behaviour" (bits 4-7: 0 a separate CancelCase branch, 1
      # cancel disabled, 2+ "act as if choice N-2 was picked" -- cross-
      # confirmed against the wolfrpg-map-parser crate's own independent
      # `CancelCase` enum and the manual's own numbered description) and,
      # unimplemented here, a left/right-key or forced-interrupt extra-case
      # bitmask (bits 8-10 -- real command dumps from the sample game never
      # carry any of these three bits set, so there is no real example to
      # cross-check the crate's own `ExtraCases` struct against; logged and
      # the whole construct skipped rather than guessed at). The choice
      # texts are the command's own string arguments, one per slot
      # (`cmd.strings`); a blank one is not selectable (help/04ev_select
      # .html's own documented "文字列が空白ならその選択肢が消去される") but
      # still owns a real ChoiceCase marker, and if *every* slot is blank
      # the whole command -- markers, cases, all of it -- is skipped
      # ("文字列が全て空だった場合は、選択肢コマンド自体がスキップされる").
      #
      # No native choice window is drawn (mirroring Message(101)'s own
      # "stderr line, no real window" scope); this is the same "wait for
      # real player input via RGSS::Input, dispatch by index" primitive the
      # RPG Basic System's own Picture-drawn menus sit on top of. Suspends
      # the Fiber every frame it has nothing to report -- exactly like
      # #exec_wait -- so a soak check with no real player supplying input
      # spins here until its own dispatched-command safety net catches it
      # (already an accepted, documented outcome category: see
      # scripts/wolf_interpreter_check.rb's own "suspected infinite loop (or
      # a real input-wait loop this soak check cannot satisfy)" note).
      def exec_choices(cmd)
        options = cmd.arg(0)
        selected = options & 0x0f
        cancel_word = (options >> 4) & 0x0f
        extra = (options >> 8) & 0x07

        if selected == 0
          @interp.unimplemented("Choices(102) with no choices configured")
          return
        end
        if extra != 0
          @interp.unimplemented("Choices(102) left/right-key or forced-interrupt branch")
          skip_to(cmd.indent) { |c| c.code == Interpreter::C_BRANCH_END }
          return
        end

        texts = cmd.strings
        visible = (0...selected).reject { |i| (texts[i] || "").empty? }
        if visible.empty?
          skip_to(cmd.indent) { |c| c.code == Interpreter::C_BRANCH_END }
          return
        end

        $stderr.puts "[Wolf-CHOICE] #{visible.map { |i| texts[i] }.join(' / ')}"

        cancel_disabled = cancel_word == Interpreter::CHOICE_CANCEL_DISABLED
        cancel_separate = cancel_word == Interpreter::CHOICE_CANCEL_SEPARATE
        cursor = 0
        chosen = nil
        canceled = false
        until chosen || canceled
          Fiber.yield
          case @interp.current_scene&.choice_input
          when :down then cursor = (cursor + 1) % visible.size
          when :up then cursor = (cursor - 1) % visible.size
          when :confirm then chosen = visible[cursor]
          when :cancel
            next if cancel_disabled
            if cancel_separate
              canceled = true
            else
              chosen = cancel_word - 2
            end
          end
        end

        select_branch(cmd.indent) { |idx| idx == chosen }
      end

      # InputKey(123), "Basic" mode only ("基本" -- confirm/cancel/sub/
      # direction, help/Ev_keyinput.png's own screenshot: "キー種 基本
      # （決定/ｷｬﾝｾﾙ/ｻﾌﾞ/方向）"). Only 2-argument calls are handled --
      # every real one in the sample game's own data (54 of 58; the
      # remaining 4 carry a 3rd argument this reader has not placed) has
      # exactly that shape, and (structurally, not semantically -- no
      # separate "which of Basic/keyboard-all/mouse/gamepad" field has
      # been found in this reader's own framing) the other three "キー種"
      # (key kind) modes are never exercised by any real command in the
      # sample game either, so there is nothing to cross-check a discriminator
      # field against even if one exists. arg(0) is the target; arg(1)
      # packs (cross-confirmed against the wolfrpg-map-parser crate's own
      # `BasicOptions` struct) a direction-keys mode (low nibble --
      # `Interpreter::INPUT_KEY_DIRECTIONS`' own keys are the ones real
      # data actually uses: 0 none, 1 all four cardinal, 7 up/down, 8
      # left/right; 2/3/4/5/6 -- 8-way and the four single-direction modes
      # -- are logged and skipped, not guessed, for lack of a real
      # example), confirm/cancel/sub-key enable bits (0x10/0x20/0x40), and
      # a "wait until pressed" bit (0x80). The returned key codes (10
      # confirm, 11 cancel, 12 sub, 2/4/6/8 down/left/right/up) are the
      # editor's own documented ones, read straight off the same
      # screenshot -- not reverse-engineered. `@interp.current_scene`'s
      # own default key bindings (confirm C, cancel B, sub Shift) match
      # help/04ev_keyinput.html's own documented defaults
      # ("決定キー(Enter/スペース)"/"キャンセルキー(Esc/Backspace/Delete)"/
      # "サブキー(Shift)"); the "システム変数52～57で...設定した" custom-
      # keycode override is not modeled. Checks every frame it has nothing
      # to report -- exactly `#exec_wait`/`#exec_choices`'s own shape --
      # when the "wait until pressed" bit is set; otherwise reports once,
      # immediately (0 when nothing configured is currently down, per the
      # manual's own "何もなければ0が代入されます").
      def exec_input_key(cmd)
        unless cmd.args.size == 2
          @interp.unimplemented("InputKey(123) with #{cmd.args.size} arguments (only the confirmed 2-argument Basic-mode layout is understood)")
          return
        end
        options = cmd.arg(1)
        keys = @interp.input_key_candidates(options)
        if keys.nil?
          @interp.unimplemented("InputKey(123) direction mode #{options & 0x0f}")
          return
        end
        target = cmd.arg(0)
        wait = !keys.empty? && (options & 0x80) != 0
        loop do
          pressed = keys.find { |k| @interp.current_scene&.input_key_pressed?(k) }
          if pressed
            @interp.var_store.set_number(target, Interpreter::INPUT_KEY_CODE[pressed])
            return
          end
          unless wait
            @interp.var_store.set_number(target, 0)
            return
          end
          Fiber.yield
        end
      end

      # The index of the StartLoop/LoopTimes enclosing the BreakLoop/
      # GotoLoopStart command @index has just moved past, found by
      # bracket-matching backward: a LoopEnd met along the way belongs to
      # an already-closed nested loop, so the opener that closes *it* is
      # skipped too (depth-tracked) rather than mistaken for the enclosing
      # loop.
      def enclosing_loop_start_index
        i = @index - 2
        depth = 0
        while i >= 0
          c = @commands[i]
          if c.code == Interpreter::C_LOOP_END
            depth += 1
          elsif c.code == Interpreter::C_START_LOOP || c.code == Interpreter::C_LOOP_TIMES
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

      # The index of the StartLoop/LoopTimes that opens the loop the
      # LoopEnd @index has just moved past closes -- found at the same
      # indent as that LoopEnd itself (loop bodies are always one indent
      # deeper than their own opener/closer), so unlike
      # #enclosing_loop_start_index this needs no bracket-depth tracking.
      def find_loop_start(indent)
        i = @index - 2 # the LoopEnd we just consumed
        while i >= 0
          c = @commands[i]
          if c.indent == indent && (c.code == Interpreter::C_START_LOOP || c.code == Interpreter::C_LOOP_TIMES)
            return i
          end
          i -= 1
        end
        nil
      end

      # `i` is a StartLoop/LoopTimes's own index, closed (naturally via
      # LoopEnd, or early via GotoLoopStart -- 04ev_control.html treats
      # both as "one iteration ends") by the command @index has just moved
      # past. StartLoop always jumps back; LoopTimes decrements its own
      # remaining count and either jumps back (count left) or ends the loop
      # (exhausted) -- `@loop_counters[i] || 1` covers a LoopTimes loop
      # entered by a JumpLabel from *outside* it, whose own count was never
      # initialized: 04ev_control.html documents this as running exactly
      # once, matching a fresh count of 1.
      #
      # `from_loop_end` distinguishes the two ways a loop can be "closed"
      # here: true when @index has *already* stepped past this loop's own
      # LoopEnd (dispatched naturally, nothing more to do once exhausted --
      # #skip_to-ing to find it again would run right past the next one
      # instead), false when GotoLoopStart calls this from mid-body and an
      # exhausted count must still #skip_to the LoopEnd itself, exactly
      # like BreakLoop.
      def continue_loop(i, from_loop_end:)
        if @commands[i].code == Interpreter::C_LOOP_TIMES
          remaining = (@loop_counters[i] || 1) - 1
          if remaining <= 0
            @loop_counters.delete(i)
            skip_to(@commands[i].indent) { |c| c.code == Interpreter::C_LOOP_END } unless from_loop_end
            return
          end
          @loop_counters[i] = remaining
        end
        @index = i + 1
      end

      # LoopTimes(179)'s own entry point: 0 (or fewer) iterations means the
      # body never runs at all (04ev_control.html's own documented
      # behavior), matching #skip_to's own use for a false branch condition
      # rather than a dedicated code path.
      def exec_loop_times(cmd)
        i = @index - 1
        total = @interp.var_store.number(cmd.arg(0))
        if total <= 0
          skip_to(cmd.indent) { |c| c.code == Interpreter::C_LOOP_END }
          return
        end
        @loop_counters[i] = total
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
      # Runtime position/facing, one entry per map event id, created lazily
      # (seeded from the event's own parsed start position) the first time
      # anything asks -- the *parsed* Wolf::Event/Page objects stay
      # immutable data, the same separation mruby-rpg2k's own Game::Character
      # keeps from its own read-only LcfMapEvent.
      @event_positions = {}
      @rng = Rng.new
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

    # The running WolfRPG::MapScene, so #exec_picture can ask it to actually
    # show/move/erase a picture sprite -- Interpreter itself has no
    # rendering code of its own, the same separation #current_map's own
    # doc comment describes for map-event lookups. nil in contexts with no
    # real scene (scripts/wolf_interpreter_check.rb's soak check), which
    # #exec_picture must tolerate.
    attr_accessor :current_scene

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
        when 0x3 then right == 0 ? 0 : (left / right)
        when 0xf then right # "Nothing": use the right-hand side as-is
        else
          var_store.warn_once("calc-op-#{calc_op}", "SetVariable calculation op #{calc_op} not implemented; using the right-hand side")
          right
        end

      current = var_store.number(target)
      var_store.set_number(target, fold32(apply_assign_op(current, computed, assign_op)))
    end

    # SetVariable(121)'s own assignment-operator word (help/06valuenext
    # .html's own "計算式の説明": =/+=/-=/*=//=/%=/min/max/abs), shared with
    # SetVariableEx(124) below -- the wolfrpg-map-parser crate's own
    # `AssignmentOperator` enum for *that* command uses the identical 0-8
    # numbering (it adds nothing SetVariable's own reader did not already
    # cross-confirm independently).
    def apply_assign_op(current, computed, assign_op)
      case assign_op
      when 0x0 then computed
      when 0x1 then current + computed
      when 0x2 then current - computed
      when 0x3 then current * computed
      when 0x4 then computed == 0 ? 0 : (current / computed)
      when 0x5 then computed == 0 ? 0 : (current % computed)
      when 0x6 then [current, computed].min
      when 0x7 then [current, computed].max
      when 0x8 then computed.abs
      else
        var_store.warn_once("assign-op-#{assign_op}", "assignment operator #{assign_op} not implemented; assigning directly")
        computed
      end
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

    # Sound(140): arg(0) packs, byte by byte (cross-confirmed against the
    # wolfrpg-map-parser crate's own `Options`/`SoundType` structs -- its own
    # 1-byte `options` + 2-byte `systemdb_entry` + 1-byte `sound_type` read
    # is exactly this reader's single 4-byte `arg(0)` word, byte for byte):
    # byte 0 low nibble "process type" (0 normal playback, 1 preload, 3 free
    # unused memory), byte 0 high nibble "operation" (0 BGM, 1 BGS, 2 SE),
    # bytes 1-2 a system-database entry index, signed 16-bit (-1 is the
    # manual's own documented "(停止)" stop sentinel), byte 3 "sound type"
    # (0 a direct system-database selection, 1 a variable naming one, 2 a
    # literal/string-variable filename). Two combinations are implemented:
    # "normal playback of an SE by filename" (the confirmed 6/7-argument
    # layout every real match in the sample game's own data carries, volume
    # at arg(4) and frequency/pitch at arg(5) -- both vary from their
    # 100/100 default in at least one real call, confirming the slots), and
    # "BGM/BGS by a direct system-database selection" (#exec_sound_track_db_
    # entry's own comment). Everything else (a variable sound source,
    # preload/free-memory, any other argument count) is logged and skipped,
    # the same discipline as every other WOLF command whose full argument
    # layout this reader has not cross-checked. A filename that is itself
    # one of WOLF's own "\cself[N]"/"\s[N]" string-interpolation escapes
    # (real, found in the sample game's own Common Events) needs a string-
    # escape engine this reader does not have for *any* command yet
    # (Message(101) does not expand them either) and is skipped the same
    # way a Picture(150) special file directive is.
    SOUND_PROCESS_PLAYBACK = 0
    SOUND_OP_BGM = 0
    SOUND_OP_BGS = 1
    SOUND_OP_SE = 2
    SOUND_TYPE_DB_ENTRY = 0
    SOUND_TYPE_FILENAME = 2
    SOUND_DB_STOP = -1

    def exec_sound(cmd)
      header = cmd.arg(0)
      process_type = header & 0x0f
      operation = (header >> 4) & 0x0f
      sound_type = (header >> 24) & 0xff

      unless process_type == SOUND_PROCESS_PLAYBACK
        unimplemented("Sound(140) process type #{process_type}")
        return
      end

      if (operation == SOUND_OP_BGM || operation == SOUND_OP_BGS) && sound_type == SOUND_TYPE_DB_ENTRY
        exec_sound_track_db_entry(cmd, header, operation)
        return
      end

      unless operation == SOUND_OP_SE && sound_type == SOUND_TYPE_FILENAME
        unimplemented("Sound(140) operation #{operation}/sound type #{sound_type}")
        return
      end
      unless cmd.args.size == 6 || cmd.args.size == 7
        unimplemented("Sound(140) SE-by-filename with #{cmd.args.size} arguments (only the confirmed 6/7-argument layout is understood)")
        return
      end

      path = cmd.strings.first || ""
      if path.start_with?("\\")
        unimplemented("Sound(140) string-interpolated filename #{path.inspect}")
        return
      end

      volume = var_store.number(cmd.arg(4))
      pitch = var_store.number(cmd.arg(5))
      current_scene&.play_se(path, volume, pitch)
    end

    # BGM/BGS "direct system-database selection" (help/05systemtype.html's
    # own "タイプ1 BGMリスト/タイプ2 BGSリスト": filename, volume%,
    # frequency%, loop start ms). Cross-confirmed end to end against the
    # sample game's own real data: `map1 ev#13`'s two real Sound calls
    # decode to system-database entry 1 (whose own *name* -- read straight
    # off `Wolf::Project::SYS_BGM_LIST`'s table -- is literally
    # "スタッフロール" [staff roll], and the very next thing the same
    # script does is show its own staff-roll credits) and entry -1 (the
    # manual's own documented stop sentinel, packed the same signed-16-bit
    # way this reader already decodes). Only 4-argument calls are handled
    # -- both real examples have exactly 4 -- and only this sound type:
    # help/04ev_sound.html's own words, volume/frequency are settable
    # *only* in Filename mode, so a database-entry call always uses the
    # table's own stored values (0 meaning "use the file's own default",
    # matching `RGSS::Audio`'s own default of 100). The fade-time argument
    # (`arg(1)`, present and identical across both real examples, but
    # without a confirmed unit) is read by neither this method nor
    # `WolfRPG::MapScene#play_track` -- playback snaps immediately, the
    # same simplification Picture(150)'s own `process_time` already gets.
    def exec_sound_track_db_entry(cmd, header, operation)
      unless cmd.args.size == 4
        unimplemented("Sound(140) BGM/BGS database entry with #{cmd.args.size} arguments (only the confirmed 4-argument layout is understood)")
        return
      end
      entry = (header >> 8) & 0xffff
      entry -= 0x1_0000 if entry >= 0x8000

      if entry == SOUND_DB_STOP
        current_scene&.stop_track(operation)
        return
      end

      table = project.system_db[operation == SOUND_OP_BGM ? Wolf::Project::SYS_BGM_LIST : Wolf::Project::SYS_BGS_LIST]
      path = table && table.value(entry, 0)
      unless path.is_a?(String) && !path.empty?
        unimplemented("Sound(140) BGM/BGS database entry #{entry}: no such entry")
        return
      end
      volume = table.value(entry, 1) || 0
      pitch = table.value(entry, 2) || 0
      volume = 100 if volume == 0
      pitch = 100 if pitch == 0
      current_scene&.play_track(operation, path, volume, pitch)
    end

    # InputKey(123)'s own "Basic" mode -- see Run#exec_input_key's own
    # comment for the full cross-check. The editor's own documented key
    # codes (help/Ev_keyinput.png's screenshot): direction keys return the
    # numpad-style code of whichever one is down (2/4/6/8), confirm/cancel/
    # sub return 10/11/12.
    INPUT_KEY_DIRECTIONS = {
      0 => [].freeze,                    # "指定なし" (none)
      1 => [:up, :down, :left, :right].freeze, # "4方向" (all four cardinal)
      7 => [:up, :down].freeze,          # "上下" (up/down only)
      8 => [:left, :right].freeze,       # "左右" (left/right only)
    }.freeze
    INPUT_KEY_CODE = { up: 8, down: 2, left: 4, right: 6, confirm: 10, cancel: 11, subkey: 12 }.freeze

    # The keys `options` (InputKey(123)'s own arg(1)) asks about, in the
    # fixed check order direction-keys-then-confirm-then-cancel-then-sub --
    # ties (more than one candidate down at once) are not modeled beyond
    # that order, since no real command in the sample game exercises the
    # question. `nil` when the direction-keys nibble is not one of the
    # confirmed values above.
    def input_key_candidates(options)
      directions = INPUT_KEY_DIRECTIONS[options & 0x0f]
      return nil unless directions
      keys = directions.dup
      keys << :confirm if (options & 0x10) != 0
      keys << :cancel if (options & 0x20) != 0
      keys << :subkey if (options & 0x40) != 0
      keys
    end

    # Picture(150) operation nibble (bits 0-3 of arg(0)).
    PICTURE_OP_SHOW = 0
    PICTURE_OP_MOVE = 1
    PICTURE_OP_ERASE = 2
    PICTURE_OP_DELAY_RESET = 3

    # Picture(150) display-type field (bits 4-6): what the picture shows.
    PICTURE_TYPE_FILE = 0
    PICTURE_TYPE_FILE_VARIABLE = 1
    PICTURE_TYPE_TEXT = 2
    PICTURE_TYPE_WINDOW_FILE = 3
    PICTURE_TYPE_WINDOW_VARIABLE = 4

    # The "Base" argument layout's fixed size: 11 slots when the picture's
    # content (filename or text) is the command's own string argument
    # (file/text/window-file), one more when it is a string-variable
    # reference instead (file-by-variable/window-by-variable), which needs
    # an extra trailing arg to name that variable. Real command dumps from
    # the sample game confirm this for every *Show* call whose other mode
    # bits (zoom mode, colours, ...) are all left at their "Normal"/default
    # value; anything else -- a Move whose zoom mode is "same as current",
    # a "Colors" or multi-corner variant -- carries a different argument
    # count this reader has not reverse-engineered, so #exec_picture_show_or_move
    # checks `cmd.args.size` against these before trusting the slot layout
    # below at all, rather than risk silently misreading a differently-shaped
    # command as this one.
    PICTURE_ARGC_LITERAL = 11
    PICTURE_ARGC_VARIABLE = 12
    PICTURE_VARIABLE_CONTENT_TYPES = [PICTURE_TYPE_FILE_VARIABLE, PICTURE_TYPE_WINDOW_VARIABLE].freeze

    # Picture(150)'s window display type (3/4) can carry a special string
    # instead of a real filename, drawing a procedural shape rather than
    # loading an image -- help/04ev_picture.html's "隠し機能 図形表示",
    # fully documented rather than reverse-engineered, and confirmed to be
    # exactly what the sample game's own custom-drawn menus use for their
    # boxes, gradients and divider lines (their own Picture calls carry
    # these literal strings). Only the shapes below are implemented, since
    # they cover every one of the sample game's own uses; <CIRCLE>/
    # <TRI-*>/<CUT/...>/<SCREENSHOT> and anything else fall through to an
    # explicit no-op instead. "角度" (angle) is documented to have no
    # effect on any of these (always 0), so callers never need to apply it.
    SHAPE_SQUARE = /\A<SQUARE>(FRAME)?\z/
    SHAPE_GRADIENT = /\A<GRAD([XY])-(\d)(\d)(\d)-(\d)(\d)(\d)>\z/
    SHAPE_LINE = /\A<LINE(?:-(\d+))?>\z/

    # Picture(150): the single command the RPG Basic System uses to draw
    # everything visible -- message windows, choice menus, the whole
    # in-game menu -- so cross-validating this one command matters more
    # than any other. No wine reference exists for WOLF RPG Editor; the
    # bitmask below is cross-confirmed between the wolfrpg-map-parser
    # crate's own independent byte-level Options/DisplayOperation/
    # DisplayType/BlendingMethod/Anchor/Zoom decoders and WolfTL's own
    # (narrower) Type() accessor, and both agree with the manual's own
    # ピクチャ command page (help/04ev_picture.html), which documents the
    # same 4 operations and 5 display kinds in the same order:
    #
    #   bits 0-3   operation:    0 show, 1 move, 2 erase, 3 "delay reset"
    #   bits 4-6   display type: 0 file, 1 file-by-string-variable,
    #                            2 text ("string as picture"), 3 window
    #                            (from a file), 4 window (from a string
    #                            variable)
    #   bits 8-11  blend:        0 normal, 1 add, 2 subtract, 3 multiply,
    #                            0xf "same as current" (leave alone)
    #   bits 12-15 anchor:       0 top-left, 1 center, 2 bottom-left,
    #                            3 top-right, 4 bottom-right (the manual
    #                            documents 2 more -- top-center/bottom-
    #                            center -- that neither independent
    #                            source's own enum models; treated as
    #                            unsupported rather than guessed)
    #   bits 20-23 zoom mode:    0 one value for both axes, 3 separate
    #                            width/height values, 4 "same as current"
    #   bit 24     "range" (apply to a contiguous run of picture numbers)
    #   bit 26     "free transform" (4 independent corner points)
    #
    # Only the crate's own byte-level parser models the *argument*
    # layout beyond this bitmask (WolfTL never needs more than the type/
    # number/text to extract translatable strings), so unlike the
    # bitmask fields above, the argument positions below are single-
    # source and cross-checked here only empirically: against many real
    # command dumps from the sample game -- filenames like
    # "SystemFile/TitleGraphic.png"/"CharaChip/Special_Tiga.png" (already
    # relative to the project's own `Data/` folder, so no separate
    # "Picture folder" guess is needed), a "window-by-string-variable"
    # call whose width/height/position arguments resolve, through
    # SetVariable math earlier in the same Common Event, to values that
    # only make sense in this exact slot order, and the sample game's own
    # custom-drawn menus using the manual's documented shape-picture
    # strings for their boxes/gradients/lines (see docs/adr/0067/0068).
    # Only the plain "Base" layout (no range, no free-transform, and a
    # "Normal" zoom mode -- #exec_picture_show_or_move checks
    # `cmd.args.size` before trusting this at all, since a Move whose zoom
    # mode is "same as current" or a "Colors"/multi-corner variant carries
    # a different, unconfirmed argument count) is implemented. Move and
    # Show both snap immediately -- WOLF's own gradual "process_time"
    # fade/slide animation is not modeled.
    def exec_picture(cmd)
      options = cmd.arg(0)
      operation = options & 0x0f
      number = cmd.arg(1)

      if operation == PICTURE_OP_ERASE
        current_scene&.erase_picture(number)
        return
      end

      range = (options >> 24) & 0x1
      free_transform = (options >> 26) & 0x1
      if range != 0 || free_transform != 0
        unimplemented("Picture(150) range/free-transform variant")
        return
      end

      case operation
      when PICTURE_OP_SHOW, PICTURE_OP_MOVE
        exec_picture_show_or_move(cmd, options, operation, number)
      when PICTURE_OP_DELAY_RESET
        unimplemented("Picture(150) delay reset")
      else
        unimplemented("Picture(150) operation #{operation}")
      end
    end

    def exec_picture_show_or_move(cmd, options, operation, number)
      display_type = (options >> 4) & 0x07
      expected_argc = PICTURE_VARIABLE_CONTENT_TYPES.include?(display_type) ? PICTURE_ARGC_VARIABLE : PICTURE_ARGC_LITERAL
      if cmd.args.size != expected_argc
        unimplemented("Picture(150) display type #{display_type} with #{cmd.args.size} arguments (only the plain layout is understood)")
        return
      end

      div_w = cmd.arg(3)
      div_h = cmd.arg(4)
      pattern = cmd.arg(5)
      opacity = var_store.number(cmd.arg(6))
      x = var_store.number(cmd.arg(7))
      y = var_store.number(cmd.arg(8))

      zoom_mode = (options >> 20) & 0xf
      zoom = zoom_mode == 4 ? nil : var_store.number(cmd.arg(9)) / 100.0
      unimplemented("Picture(150) separate width/height zoom") if zoom_mode == 3

      angle = var_store.number(cmd.arg(10))

      blend_word = (options >> 8) & 0xf
      blend =
        case blend_word
        when 0xf then nil # "same as current" -- leave the sprite's blend mode alone
        when 0, 1, 2 then blend_word
        else
          var_store.warn_once("picture-blend-#{blend_word}", "Picture(150) blend mode #{blend_word} not supported; using normal")
          0
        end
      anchor = (options >> 12) & 0xf

      # A Move never respecifies the picture's content -- it only updates
      # the transform of whatever is already showing under this number.
      if operation == PICTURE_OP_MOVE
        current_scene&.move_picture(number, x, y, opacity, zoom, angle, blend)
        return
      end

      content =
        if PICTURE_VARIABLE_CONTENT_TYPES.include?(display_type)
          var_store.string(cmd.arg(11))
        else
          cmd.strings.first || ""
        end

      case display_type
      when PICTURE_TYPE_TEXT
        current_scene&.show_string_picture(number, content, x, y, opacity, zoom, angle, anchor, blend)
      when PICTURE_TYPE_FILE, PICTURE_TYPE_FILE_VARIABLE
        if content.start_with?("<")
          unimplemented("Picture(150) special file directive #{content.inspect}")
          return
        end
        current_scene&.show_file_picture(number, content, div_w, div_h, pattern, x, y, opacity, zoom, angle, anchor, blend)
      when PICTURE_TYPE_WINDOW_FILE, PICTURE_TYPE_WINDOW_VARIABLE
        shape = parse_shape_tag(content)
        unless shape
          unimplemented("Picture(150) window picture #{content.inspect} (only <SQUARE>/<GRADX-.../<GRADY-.../<LINE> shapes render so far)")
          return
        end
        current_scene&.show_shape_picture(number, shape, div_w, div_h, x, y, opacity, zoom, blend)
      else
        unimplemented("Picture(150) display type #{display_type}")
      end
    end

    def parse_shape_tag(str)
      if (m = SHAPE_SQUARE.match(str))
        return { kind: :square, frame: !m[1].nil? }
      end
      if (m = SHAPE_GRADIENT.match(str))
        return {
          kind: :gradient,
          axis: m[1] == "X" ? :x : :y,
          color1: shape_color(m[2], m[3], m[4]),
          color2: shape_color(m[5], m[6], m[7]),
        }
      end
      if (m = SHAPE_LINE.match(str))
        return { kind: :line, thickness: m[1] ? m[1].to_i : 1 }
      end
      nil
    end

    # Each digit is a 0-9 intensity level for one RGB channel (the
    # manual's own examples: "000" black, "999" white, "090" green),
    # scaled to the usual 0-255 range.
    def shape_color(r, g, b)
      [r, g, b].map { |d| (d.to_i * 255 / 9.0).round }
    end

    # Event movement: a map event page's own ambient "動作" (Page#move_type
    # -- None/Custom/Random/TowardHero, cross-confirmed against the
    # wolfrpg-map-parser crate's own independent `MoveRoute` enum, byte for
    # byte) and SetMoveRoute(201)'s explicit "動作指定" command, which can
    # redirect any event -- or the hero -- mid-script. Both play back the
    # same RouteCommand list (help/04ev_movesettingB.html's own "動作指定
    # ウィンドウ"), whose per-step `id`/argument-count framing is proven (the
    # whole sample game's Common Events and map events parse with nothing
    # left over -- WolfTL's own RouteCommand.hpp reads the identical 1-byte
    # id + 1-byte arg count + N ints + 2-byte terminator shape), but whose
    # *meaning* is single-source: the crate's own `MoveType` enum, whose
    # English names this reader cross-checked one by one against
    # help/Ev_routeset.png's own Japanese button labels (every id
    # implemented below lines up: id 0-3 the plain movement arrows, 8-11 the
    # "方向転換" facing arrows, 16-20/22-27 named buttons like "ランダム移動"/
    # "主人公に接近"/"右に回転"). Real command dumps from the sample game
    # carry ids (21, 29, 47, 60) this reader could not place in the crate's
    # own table at all -- diagonal movement/facing (ids 4-7/12-15, which
    # would need a diagonal passability model this reader does not have) and
    # every setter/toggle id (speed/frequency/graphic/opacity/height/sound/
    # variable/jump/approach-position, ids 32 and up) are left unimplemented
    # too, rather than guessed -- see docs/adr/0069 for the full breakdown.
    DIRECTION_DELTA = { down: [0, 1], up: [0, -1], left: [-1, 0], right: [1, 0] }.freeze
    # The reverse of DIRECTION_DELTA -- a plain literal rather than
    # `DIRECTION_DELTA.key(...)`, since `Hash#key` (the reverse-lookup
    # method) does not exist anywhere in this project's vendored mruby fork
    # (confirmed empirically: `ctest -R mruby_test` raises "undefined method
    # 'key' for Hash" for it, and no other gem in this codebase calls it
    # either -- AGENTS.md's own "mruby stdlib methods live in core *-ext
    # mrbgems" note is about methods that exist but need a declared
    # dependency; this one is not that case).
    DELTA_DIRECTION = { [0, 1] => :down, [0, -1] => :up, [-1, 0] => :left, [1, 0] => :right }.freeze
    DIRECTION_ORDER = [:down, :left, :up, :right].freeze

    # A tiny deterministic pseudo-random generator for MoveRandom/
    # TurnLeftRightRandom/FaceRandomDirection's own "pick one" need, mirroring
    # mruby-rpg2k's own Game::Rng (game.rb's own comment there: `Array#sample`
    # lives in mruby-random, a dependency this gem does not declare and, per
    # the same build's own comment, this engine's code deliberately avoids in
    # favour of a seeded LCG even where the gem *is* available, so a future
    # frame-by-frame diff against a genuine reference stays possible). WOLF RPG
    # Editor has no such reference yet (docs/adr/0064), so reproducibility is
    # not load-bearing here the way it is for RPG2000's own move routes --
    # kept anyway for consistency, and because it sidesteps the missing-gem
    # trap entirely.
    class Rng
      PERIOD = 65_537
      def initialize(seed = 1)
        @state = (seed & 0xffff) + 1
      end
      def next_int
        @state = (@state * 75 + 74) % PERIOD
      end
      # An integer in 0...n (0 when n <= 0).
      def random(n)
        return 0 if n <= 0
        next_int % n
      end
    end

    ROUTE_MOVE_DOWN = 0
    ROUTE_MOVE_LEFT = 1
    ROUTE_MOVE_RIGHT = 2
    ROUTE_MOVE_UP = 3
    ROUTE_FACE_DOWN = 8
    ROUTE_FACE_LEFT = 9
    ROUTE_FACE_RIGHT = 10
    ROUTE_FACE_UP = 11
    ROUTE_MOVE_RANDOM = 16
    ROUTE_MOVE_TOWARD_HERO = 17
    ROUTE_MOVE_AWAY_FROM_HERO = 18
    ROUTE_STEP_FORWARD = 19
    ROUTE_STEP_BACKWARD = 20
    ROUTE_TURN_RIGHT = 22
    ROUTE_TURN_LEFT = 23
    ROUTE_TURN_RANDOM = 24
    ROUTE_FACE_RANDOM = 25
    ROUTE_FACE_TOWARD_HERO = 26
    ROUTE_FACE_AWAY_FROM_HERO = 27

    ROUTE_MOVE_DELTA = {
      ROUTE_MOVE_DOWN => DIRECTION_DELTA[:down], ROUTE_MOVE_LEFT => DIRECTION_DELTA[:left],
      ROUTE_MOVE_RIGHT => DIRECTION_DELTA[:right], ROUTE_MOVE_UP => DIRECTION_DELTA[:up],
    }.freeze
    ROUTE_FACE_DIRECTION = {
      ROUTE_FACE_DOWN => :down, ROUTE_FACE_LEFT => :left,
      ROUTE_FACE_RIGHT => :right, ROUTE_FACE_UP => :up,
    }.freeze

    # SetMoveRoute(201)'s own "動作指定する対象" target encoding
    # (help/04ev_movesettingB.html: ">=0 the event with that id, -1 this
    # event, -2 the hero (party leader), -3..-7 party member 1-5"). No party
    # system exists yet, so a party-member target is logged and skipped the
    # same as any other not-yet-modeled command.
    ROUTE_TARGET_SELF = -1
    ROUTE_TARGET_HERO = -2

    # How far (Manhattan distance) MoveTowardHero/Page#move_type's own
    # "TowardHero" will path before falling back to a random step, per
    # help/04eventwindowB.html's own qualitative note ("ただし、ある程度距離が
    # 離れるとランダム移動になります" -- "once far enough away it becomes
    # random movement") -- no source gives the exact distance, so this is a
    # reasonable round number, not a decoded constant.
    TOWARD_HERO_RANGE = 10

    # The runtime {x:, y:, direction:, page_index:, move_timer:} for one map
    # event, created on first use from its own parsed start position.
    def event_position(event)
      @event_positions[event.id] ||= { x: event.x, y: event.y, direction: :down, page_index: nil, move_timer: 0 }
    end

    # SetMoveRoute(201): args = [target]; `cmd.route`/`cmd.route_flags` are
    # already parsed by the shared Command framing (interpreter.rb's own
    # header). The "動作を繰り返す" [loop] option is not modeled -- applying a
    # route instantly (like every other command here) would spin forever if
    # it looped and moved at all, so a looping route is logged and skipped
    # entirely rather than run once and silently dropping the loop.
    def exec_set_move_route(cmd)
      pos, writeback = resolve_route_target(cmd.arg(0))
      unless pos
        unimplemented("SetMoveRoute(201) target #{cmd.arg(0)}")
        return
      end
      if ((cmd.route_flags || 0) & 0x01) != 0
        unimplemented("SetMoveRoute(201) repeating route")
        return
      end
      run_route_commands(pos, cmd.route || [])
      writeback&.call(pos)
    end

    def resolve_route_target(target)
      pos, event = resolve_character_pos(target)
      return [nil, nil] unless pos
      # #exec_set_move_route's own generic "target N" message covers a
      # dangling event id, a "this event" outside any map event's own
      # context, or a party member (-3..-7, no party system exists yet) --
      # #resolve_character_pos returns nil pos for all three.
      writeback = target == ROUTE_TARGET_HERO ? ->(p) { current_scene.hero_pos = p } : nil
      [pos, writeback]
    end

    # Shared by SetMoveRoute(201) and SetVariableEx(124)'s own Character
    # mode: help/04ev_movesettingB.html's documented target convention
    # (>=0 an event id, -1 this event, -2 the hero, -3..-7 a party member --
    # no party system exists yet) resolved to a `{x:, y:, direction:}` pos
    # hash and, when it names a real map event (not the hero), that event
    # itself (for SetVariableEx's own EventId field). `[nil, nil]` when
    # nothing resolves.
    def resolve_character_pos(target)
      if target >= 0
        event = current_map && current_map.events.find { |e| e.id == target }
        return [nil, nil] unless event
        [event_position(event), event]
      elsif target == ROUTE_TARGET_SELF
        event_id = var_store.current_map_event_id
        event = event_id && current_map && current_map.events.find { |e| e.id == event_id }
        return [nil, nil] unless event
        [event_position(event), event]
      elsif target == ROUTE_TARGET_HERO
        return [nil, nil] unless current_scene
        [current_scene.hero_pos, nil]
      else
        [nil, nil]
      end
    end

    # SetVariableEx(124): arg(0) the target variable, arg(1) packs (byte 0
    # unmodeled "options" -- the crate's own `bind_result`/`use_variable_as_
    # reference`/`precise_position` flags, never set by any real command in
    # the sample game -- byte 1 low nibble the assignment operator, shared
    # with SetVariable(121) via #apply_assign_op and cross-confirmed
    # identical by the crate's own `AssignmentOperator` enum, byte 1 high
    # nibble a "variable type" selecting one of four wildly different query
    # kinds: 1 Character, 2 Position [a map tile's own properties, not a
    # character's], 3 Other [current map id, BGM/BGS playback state,
    # mouse], 4 PictureNumber [a specific Picture(150) number's own state]).
    # Real command dumps from the sample game exercise Character (29 of 32
    # real calls) and Other (3, target values this reader has not wired to
    # any tracked state -- current map id, whether a BGM is playing); this
    # reader implements only Character, whose own target argument (arg(2))
    # reuses SetMoveRoute(201)'s exact target convention (see
    # #resolve_character_pos) and whose own field selector (arg(3), a
    # `CharacterField` cross-confirmed against the crate's own enum) covers
    # only what this reader's existing position tracking can answer:
    # standard and precise X/Y (help/04ev_valuenext.html's own documented
    # precise-coordinate formula -- half-tile units, X the left edge,
    # Y "the foot position minus one" -- applied exactly, not approximated,
    # since this reader has no sub-tile movement state to make it
    # imprecise), numpad-convention direction (matching every other maker
    # in this codebase's own numpad direction convention), and event id
    # (-1 when the target does not name a real map event, matching the
    # manual's own documented not-found sentinel). Every other field
    # (height, screen coordinates, shadow graphic, tile tag, on-screen,
    # active page, run condition, range extension, animation pattern,
    # moving) and every other variable type are logged and skipped.
    SET_VAR_EX_TYPE_CHARACTER = 1
    CHAR_FIELD_STANDARD_X = 0
    CHAR_FIELD_STANDARD_Y = 1
    CHAR_FIELD_PRECISE_X = 2
    CHAR_FIELD_PRECISE_Y = 3
    CHAR_FIELD_DIRECTION = 5
    CHAR_FIELD_EVENT_ID = 10
    CHAR_DIRECTION_NUMPAD = { down: 2, left: 4, right: 6, up: 8 }.freeze

    def exec_set_variable_ex(cmd)
      unless cmd.args.size == 4
        unimplemented("SetVariableEx(124) with #{cmd.args.size} arguments (only the confirmed 4-argument Character layout is understood)")
        return
      end
      header = cmd.arg(1)
      assign_op = (header >> 8) & 0x0f
      var_type = (header >> 12) & 0x0f

      unless var_type == SET_VAR_EX_TYPE_CHARACTER
        unimplemented("SetVariableEx(124) variable type #{var_type}")
        return
      end

      pos, event = resolve_character_pos(cmd.arg(2))
      unless pos
        unimplemented("SetVariableEx(124) character target #{cmd.arg(2)}")
        return
      end

      field = cmd.arg(3)
      computed =
        case field
        when CHAR_FIELD_STANDARD_X then pos[:x]
        when CHAR_FIELD_STANDARD_Y then pos[:y]
        when CHAR_FIELD_PRECISE_X then pos[:x] * 2
        when CHAR_FIELD_PRECISE_Y then pos[:y] * 2 - 1
        when CHAR_FIELD_DIRECTION then CHAR_DIRECTION_NUMPAD[pos[:direction]] || 0
        when CHAR_FIELD_EVENT_ID then event ? event.id : -1
        else
          unimplemented("SetVariableEx(124) character field #{field}")
          return
        end

      target = cmd.arg(0)
      current = var_store.number(target)
      var_store.set_number(target, fold32(apply_assign_op(current, computed, assign_op)))
    end

    # Database(250) ("ＤＢ操作"): arg(0)/arg(1)/arg(2) the db type/data/field
    # selectors (each, like every other numeric slot, a `ValueRef`-decodable
    # reference -- real data uses variable-held field selectors, not just
    # literals), arg(3) packs the crate's own `Assignment`(byte 0)/
    # `Options`(byte 1) bytes -- byte 0's low bit `use_variable_as_reference`
    # and high nibble the assignment operator shared with SetVariable(121)
    # via #apply_assign_op (identical 0-8 numbering, cross-confirmed again by
    # the crate's own enum for this command); byte 1's low nibble a `DBType`
    # (0 可変DB "changeable", 1 システムDB "system", 2 ユーザDB "user") and
    # high nibble Read(1)/Write(0) -- plus a real, non-zero third byte the
    # crate's own comment calls padding, decoded here across every real
    # occurrence in the sample game (2544) as a 3-bit "which of the three
    # optional 名前で呼出 strings are attached" flag that never disagrees
    # with the strings' own emptiness, so it adds nothing beyond what
    # `cmd.strings` already carries. Real data cross-checked directly against
    # the parsed database (`user_db[2].name == "アイテム"` for CE#0's own
    # "○アイテム増減", matching its own embedded string byte for byte) shows
    # those strings are the editor's own auto-filled display labels for the
    # current *numeric* selection, not a live name-lookup trigger switching
    # how arg(0..2) resolve -- every real command's numeric selectors already
    # name the same row/field the strings describe. `use_variable_as_
    # reference` is 0 in all 2544 real calls, so name-lookup mode (and that
    # bit) is left unimplemented rather than guessed.
    #
    # value/target lives in arg(4) when there is one (5-argument shape, the
    # dominant real case, WolfTL/the crate's own `Base` state, a plain u32);
    # a 4-argument shape (19 real, all Write) has no arg(4) at all -- the
    # value is the command's own lone string, `cmd.string(0)` (the crate's
    # own `String` state). Which of `var_store.number`/`.string` a call's
    # value/target/current actually goes through is *not* carried by the
    # packed word at all -- it is decided by the target `DBField`'s own
    # `#string?`/slot (real data confirms both directions: CE#0's own
    # "○アイテム増減" reads user DB type 2's own "アイテム名" field, a string
    # field, into common-event self-var 8, itself in the string quintet
    # (help/06valueget.html's own self-var 5-9 string band) -- reading it as
    # a *number* the way #exec_set_variable_ex's own numeric fields do would
    # silently coerce it to 0 and fire VarStore's own string/number-mismatch
    # warning on every call). Read and Write apply the identical assign-op
    # pattern SetVariable/SetVariableEx already use, current/computed simply
    # swapped: Read combines the DB's own current value with the target's
    # current value and writes the result to the target (a "get" that can
    # also be "+="); Write combines the DB's own current value with the
    # resolved source value and writes the result back into the DB
    # (confirmed by a real MinusEquals member-management call that
    # decrements an invoker-tracking field by 1 rather than overwriting it,
    # and, for strings, real PlusEquals calls that concatenate).
    #
    # Not implemented: XY配列 (a whole second, non-DBType target the manual
    # documents with its own addressing, unrelated to `DBType`'s 0-2 enum),
    # every "DB操作" utility beyond plain read/write (name<->index lookups,
    # データ数/項目数取得, 全データ初期化, 新データ挿入/データ抜き取り/
    # データコピー/データソート), and CSV import/export (a separate command,
    # ImportDatabase(251)).
    DB_OP_WRITE = 0
    DB_OP_READ = 1
    DB_TYPE_SECTION = { 0 => :changeable, 1 => :system, 2 => :user }.freeze

    def exec_database(cmd)
      unless cmd.args.size == 4 || cmd.args.size == 5
        unimplemented("Database(250) with #{cmd.args.size} arguments")
        return
      end

      packed = cmd.arg(3)
      assignment_byte = packed & 0xff
      options_byte = (packed >> 8) & 0xff
      db_op = (options_byte >> 4) & 0x0f
      section = DB_TYPE_SECTION[options_byte & 0x0f]
      use_var_ref = assignment_byte & 1
      assign_op = (assignment_byte >> 4) & 0x0f

      unless section
        unimplemented("Database(250) db type selector #{options_byte & 0x0f}")
        return
      end
      if use_var_ref != 0
        unimplemented("Database(250) name-lookup mode (use_variable_as_reference)")
        return
      end
      if cmd.args.size == 4 && db_op != DB_OP_WRITE
        unimplemented("Database(250) with 4 arguments and operation #{db_op} (only the real Write/string-literal shape is understood)")
        return
      end

      type_id = var_store.number(cmd.arg(0))
      data_id = var_store.number(cmd.arg(1))
      field_id = var_store.number(cmd.arg(2))
      db = database_section(section)
      db_type = db && db[type_id]
      unless db_type
        unimplemented("Database(250) #{section} db type #{type_id} not found")
        return
      end
      field = db_type.field(field_id)
      unless field
        unimplemented("Database(250) #{section} db type #{type_id} field #{field_id} not found")
        return
      end

      if field.string?
        exec_database_string(cmd, db_type, data_id, field_id, db_op, assign_op)
      elsif cmd.args.size == 4
        unimplemented("Database(250) 4-argument string-literal shape targeting a numeric field")
      else
        exec_database_number(cmd, db_type, data_id, field_id, db_op, assign_op)
      end
    end

    def exec_database_number(cmd, db_type, data_id, field_id, db_op, assign_op)
      case db_op
      when DB_OP_READ
        computed = db_type.value(data_id, field_id)
        computed = computed.is_a?(Integer) ? computed : 0
        target = cmd.arg(4)
        current = var_store.number(target)
        var_store.set_number(target, fold32(apply_assign_op(current, computed, assign_op)))
      when DB_OP_WRITE
        current = db_type.value(data_id, field_id)
        current = current.is_a?(Integer) ? current : 0
        computed = var_store.number(cmd.arg(4))
        db_type.set_value(data_id, field_id, fold32(apply_assign_op(current, computed, assign_op)))
      else
        unimplemented("Database(250) operation #{db_op}")
      end
    end

    def exec_database_string(cmd, db_type, data_id, field_id, db_op, assign_op)
      case db_op
      when DB_OP_READ
        computed = db_type.value(data_id, field_id)
        computed = computed.is_a?(String) ? computed : ""
        target = cmd.arg(4)
        current = var_store.string(target)
        var_store.set_string(target, apply_assign_op_string(current, computed, assign_op))
      when DB_OP_WRITE
        current = db_type.value(data_id, field_id)
        current = current.is_a?(String) ? current : ""
        computed = cmd.args.size == 4 ? cmd.string(0) : var_store.string(cmd.arg(4))
        db_type.set_value(data_id, field_id, apply_assign_op_string(current, computed, assign_op))
      else
        unimplemented("Database(250) operation #{db_op}")
      end
    end

    # Database(250)'s own string fields only ever carry assignment operator
    # 0 (=) or 1 (+=, concatenation) for real; every other operator (a
    # handful of real LowerBound calls -- presumably a stand-in for the
    # manual's own "文字列の並び替え" DB-sort feature, not a per-call
    # operation) falls through to plain assignment, matching
    # #apply_assign_op's own defensive default for an operator it does not
    # implement.
    def apply_assign_op_string(current, computed, assign_op)
      case assign_op
      when 0x0 then computed
      when 0x1 then current + computed
      else
        var_store.warn_once("assign-op-str-#{assign_op}", "assignment operator #{assign_op} not implemented for a string DB field; assigning directly")
        computed
      end
    end

    def database_section(section)
      case section
      when :changeable then project.changeable_db
      when :system then project.system_db
      when :user then project.user_db
      end
    end

    # Runs one RouteCommand list against `pos` (either a map event's own
    # runtime position, or the hero's, via #resolve_route_target) -- shared
    # by SetMoveRoute(201) and a page's own initial "カスタム" route
    # (#apply_initial_move_route). Every step applies instantly, the same
    # "snap, no gradual animation" simplification Picture(150)'s own Show/
    # Move already make (interpreter.rb's own comment on that command).
    def run_route_commands(pos, commands)
      commands.each do |rc|
        if ROUTE_MOVE_DELTA.key?(rc.id)
          dx, dy = ROUTE_MOVE_DELTA[rc.id]
          step_event_pos(pos, dx, dy)
        elsif ROUTE_FACE_DIRECTION.key?(rc.id)
          pos[:direction] = ROUTE_FACE_DIRECTION[rc.id]
        else
          case rc.id
          when ROUTE_MOVE_RANDOM then step_event_pos(pos, *random_step_delta)
          when ROUTE_MOVE_TOWARD_HERO then step_event_pos(pos, *toward_hero_delta(pos))
          when ROUTE_MOVE_AWAY_FROM_HERO then step_event_pos(pos, *away_from_hero_delta(pos))
          when ROUTE_STEP_FORWARD then step_event_pos(pos, *DIRECTION_DELTA[pos[:direction]])
          when ROUTE_STEP_BACKWARD
            dx, dy = DIRECTION_DELTA[pos[:direction]]
            step_event_pos(pos, -dx, -dy)
          when ROUTE_TURN_RIGHT then pos[:direction] = turn(pos[:direction], 1)
          when ROUTE_TURN_LEFT then pos[:direction] = turn(pos[:direction], -1)
          when ROUTE_TURN_RANDOM then pos[:direction] = turn(pos[:direction], @rng.random(2) == 0 ? -1 : 1)
          when ROUTE_FACE_RANDOM then pos[:direction] = DIRECTION_ORDER[@rng.random(DIRECTION_ORDER.size)]
          when ROUTE_FACE_TOWARD_HERO
            d = direction_toward_hero(pos)
            pos[:direction] = d if d
          when ROUTE_FACE_AWAY_FROM_HERO
            d = direction_away_from_hero(pos)
            pos[:direction] = d if d
          else
            unimplemented("move route command #{rc.id}")
          end
        end
      end
    end

    def turn(direction, steps)
      i = DIRECTION_ORDER.index(direction) || 0
      DIRECTION_ORDER[(i + steps) % DIRECTION_ORDER.size]
    end

    def random_step_delta
      DIRECTION_DELTA[DIRECTION_ORDER[@rng.random(DIRECTION_ORDER.size)]]
    end

    def hero_delta(pos)
      return [0, 0] unless current_scene
      [current_scene.x - pos[:x], current_scene.y - pos[:y]]
    end

    def dominant_delta(dx, dy)
      return [0, 0] if dx == 0 && dy == 0
      dx.abs >= dy.abs ? [dx <=> 0, 0] : [0, dy <=> 0]
    end

    def toward_hero_delta(pos)
      return random_step_delta unless current_scene
      dx, dy = hero_delta(pos)
      return random_step_delta if (dx.abs + dy.abs) > TOWARD_HERO_RANGE
      dominant_delta(dx, dy)
    end

    def away_from_hero_delta(pos)
      return random_step_delta unless current_scene
      dx, dy = hero_delta(pos)
      dominant_delta(-dx, -dy)
    end

    def direction_toward_hero(pos)
      DELTA_DIRECTION[dominant_delta(*hero_delta(pos))]
    end

    def direction_away_from_hero(pos)
      dx, dy = hero_delta(pos)
      DELTA_DIRECTION[dominant_delta(-dx, -dy)]
    end

    # Moves `pos` one tile, blocked by the map's own tile passability and
    # the hero's own tile (no other-event collision yet -- unlike the
    # hero's own #move_hero/#event_at, nothing here stops two moving events
    # from overlapping); always updates `pos[:direction]` to face the
    # attempted direction even when the step itself is blocked, matching
    # the manual's own "動作内容" list treating movement and facing as the
    # same action.
    def step_event_pos(pos, dx, dy)
      facing = DELTA_DIRECTION[[dx, dy]]
      pos[:direction] = facing if facing
      return if dx == 0 && dy == 0
      nx = pos[:x] + dx
      ny = pos[:y] + dy
      return unless current_scene && current_scene.passable?(nx, ny) && !current_scene.hero_at?(nx, ny)
      pos[:x] = nx
      pos[:y] = ny
    end

    # Not sourced from the manual's own numeric table for "移動頻度" (no
    # dropdown value list found in help/*.html, only the qualitative "raising
    # it shortens the pause after each step, 'every frame' removes the pause
    # entirely" description) -- a reasonable decreasing interval, clamped so
    # it never reaches zero (this reader has no "every frame" sentinel to
    # detect), stands in until a real source turns up.
    def move_pause_frames(frequency)
      [20 - frequency * 4, 2].max
    end

    # Advances one map event's ambient movement by one frame: applies a
    # newly-active page's own initial "カスタム" route once (Custom), or
    # ticks a Random/TowardHero step on a #move_pause_frames cadence. A page
    # with no move type (None) or a Confirm/Touch-triggered one currently
    # inactive leaves the event exactly where it already is.
    def update_event_movement(event, page_index, page)
      pos = event_position(event)
      return unless page
      if pos[:page_index] != page_index
        pos[:page_index] = page_index
        apply_initial_move_route(pos, page) if page.move_type == Wolf::Page::MOVE_CUSTOM
        pos[:move_timer] = 0
      end
      case page.move_type
      when Wolf::Page::MOVE_RANDOM then tick_ambient_move(pos, page) { random_step_delta }
      when Wolf::Page::MOVE_TOWARD_HERO then tick_ambient_move(pos, page) { toward_hero_delta(pos) }
      end
    end

    def apply_initial_move_route(pos, page)
      if ((page.route_options || 0) & 0x01) != 0
        unimplemented("map event page's own repeating custom move route")
        return
      end
      run_route_commands(pos, page.route)
    end

    def tick_ambient_move(pos, page)
      if pos[:move_timer] > 0
        pos[:move_timer] -= 1
        return
      end
      step_event_pos(pos, *yield)
      pos[:move_timer] = move_pause_frames(page.move_frequency)
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
        pos = event_position(event)
        next unless pos[:x] == x && pos[:y] == y
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
        update_event_movement(event, idx, page)
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
