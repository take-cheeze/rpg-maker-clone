module RGSS
  # The runtime-log tail that a crash report carries.
  #
  # When the engine dies, the exception alone rarely explains why: the reason is
  # in the `[RPG2k]` / `[RGSS]` lines the runtime logged on the way down (a
  # missing asset, a data field that fell back to a default, an unimplemented
  # command). Those go to `$stderr`, which on a desktop scrolls past and in the
  # browser lives in a collapsed panel — neither ends up in a bug report.
  #
  # So `install` tees `$stderr` through a ring buffer of the last MAX_LINES
  # lines. Nothing about the existing logging changes (every write still reaches
  # the real `$stderr`); the tail is simply also kept in memory, and
  # `error_dump_report` (src/error_dump.cxx) folds it into the report the player
  # copies. Each buffered line is also handed to RGSS.__log_bridge_write, which
  # forwards it to ng-log via the hook the executable installs (see
  # include/terminal.hxx's "Stderr log bridge" section) -- so the same warning
  # that lands in a crash report also respects ng-log's severity filtering and
  # shows up in the on-screen terminal log console, stamped with the script
  # location it was written at (the binding reads that off the call stack,
  # skipping the tee's own frames below). That call is guarded by
  # `respond_to?`: this file otherwise has no mruby dependency, which is what
  # lets scripts/error_report_check.rb exercise it on plain CRuby (see that
  # script and mruby-rgss/test/test.rb, which both cover this design). `$stderr`
  # is teed and `$stdout` is not: `$stderr` is where the runtime logs its
  # diagnostics by convention (see the Error Handling section of AGENTS.md).
  module ErrorReport
    # How much log to keep. Enough to cover a scene transition and the loads it
    # triggers, small enough that the report stays pasteable.
    MAX_LINES = 200

    # A single runaway line (a dumped table, a decoded blob) must not blow up
    # the report on its own.
    MAX_LINE_CHARS = 500

    # Forwards every write to the real $stderr and records whole lines. Only the
    # writing methods are spelled out; anything else a caller expects of an IO
    # (flush, sync, fileno, tty?, ...) is delegated, so this stands in for
    # $stderr without pretending to be a full IO.
    class Tee
      attr_reader :io

      def initialize(io)
        @io = io
      end

      def write(*args)
        args.each { |a| ErrorReport.record(a.to_s) }
        @io.write(*args)
      end

      def print(*args)
        args.each { |a| ErrorReport.record(a.to_s) }
        @io.print(*args)
      end

      def puts(*args)
        ErrorReport.record(ErrorReport.puts_text(args))
        @io.puts(*args)
      end

      def <<(text)
        ErrorReport.record(text.to_s)
        @io << text
        self
      end

      def method_missing(name, *args, &block)
        @io.__send__(name, *args, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @io.respond_to?(name, include_private)
      end
    end

    @lines = []
    @partial = ""
    @installed = false
    @last_location = nil

    class << self
      # The recorded lines, oldest first, newline-free.
      attr_reader :lines

      # The script location the log bridge attributed to the last line it
      # forwarded, as "file:line" — the location the engine's log stamps that
      # line with (RGSS.__log_bridge_write answers it; see
      # include/terminal.hxx's "Stderr log bridge" section). nil where nothing
      # has been forwarded, or where the binding is absent (CRuby) or could not
      # tell (bytecode built without debug info). Nothing in the runtime reads
      # it; it is how the location can be checked from Ruby, where the forward
      # itself is invisible.
      attr_reader :last_location
    end

    # Tee $stderr through the ring buffer. Called once at start-up (from
    # error_dump_install in src/error_dump.cxx, right after the interpreter is
    # opened) and a no-op afterwards, so a second call cannot stack two tees and
    # record every line twice. Returns true when it installed the tee.
    def self.install
      return false if @installed
      @installed = true
      $stderr = Tee.new($stderr)
      true
    end

    def self.installed?
      @installed
    end

    # What IO#puts writes for `args`: every argument on its own line, one bare
    # newline when there are none, no second newline after an argument that
    # already ends in one, and nested arrays flattened.
    def self.puts_text(args)
      return "\n" if args.empty?
      out = ""
      args.each do |a|
        if a.is_a?(Array)
          out += puts_text(a)
        else
          s = a.to_s
          out += s
          out += "\n" unless s[-1] == "\n"
        end
      end
      out
    end

    # Record raw log output. Writes arrive in arbitrary chunks (a `puts` is one
    # call, a `print` per fragment is many), so text is buffered until a newline
    # completes a line.
    #
    # A plain index loop rather than `each { |line| push(line) }` on purpose:
    # `each`'s block is its own call frame (Array#each is core Ruby, not a C
    # primitive), which sat between `push` and whatever called `record` on
    # every single bridged line. RGSS.__log_bridge_write's script_location walk
    # (mruby-rgss/src/lib.cxx) skips frames it recognises as this file's own
    # plumbing to find the real logging site, and that extra frame is core
    # mruby's own file (mrblib/array.rb) rather than error_report.rb, so the
    # walk stopped there and every bridged line got attributed to Array#each
    # instead of the script that logged. A `while` loop compiles with no new
    # call frame, so the frame right above `push` is `record`, and the one
    # above that is `record`'s real caller, exactly as intended.
    def self.record(text)
      parts = (@partial + text.to_s).split("\n", -1)
      @partial = parts.pop || ""
      i = 0
      while i < parts.size
        push(parts[i])
        i += 1
      end
      nil
    end

    # The recorded log as one string, newest lines last, at most `limit` of
    # them. Empty when nothing was recorded — a report then simply has no log
    # section rather than an empty fence.
    def self.log_tail(limit = MAX_LINES)
      tail = @lines
      tail = tail[-limit, limit] if limit && tail.size > limit
      tail = tail + [@partial] unless @partial.empty?
      return "" if tail.empty?
      tail.join("\n") + "\n"
    end

    # Drop everything recorded so far. Used by the tests; the runtime never
    # needs it, as the ring buffer bounds itself.
    def self.clear
      @lines = []
      @partial = ""
      @last_location = nil
      nil
    end

    def self.push(line)
      line = line[0, MAX_LINE_CHARS] + "..." if line.size > MAX_LINE_CHARS
      @lines << line
      @lines.shift while @lines.size > MAX_LINES
      if RGSS.respond_to?(:__log_bridge_write)
        @last_location = RGSS.__log_bridge_write(line)
      end
      nil
    end

    # The report path can only be trusted if it has been walked: a report that
    # dropped the backtrace or the log is worth nothing, and a crash is a bad
    # time to find out. `probe!` logs a line and then raises from a nested call,
    # so the engine side (error_dump_run_probe in src/error_dump.cxx, driven by
    # --error_dump_probe and the error_dump ctest) can read the resulting report
    # back and check both survived. The constants are the needles it looks for;
    # it reads them from here rather than repeating the strings.
    PROBE_LOG_LINE = "[ErrorDump-PROBE] a log line written before the raise"
    PROBE_MESSAGE = "error dump probe raise"

    def self.probe!
      $stderr.puts PROBE_LOG_LINE
      probe_raise
    end

    def self.probe_raise
      raise PROBE_MESSAGE
    end
  end
end
