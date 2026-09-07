# Variable/switch/string state and the "変数呼び出し値" (variable-reference
# value) addressing scheme every numeric/string field in an event command can
# use: typing 1,000,000 or more into what looks like a plain number field
# reads (or writes) a variable instead of a literal. Transcribed directly from
# the editor's own manual (help/06valueget.html, "変数呼び出し値 一覧"),
# which is unambiguous and complete for the ranges implemented here:
#
#   -999999..999999        literal
#   1000000 + 10*Y + X     map event Y's self variable X      (X: 0-9)
#   1100000 + X            this map event's self variable X   (X: 0-9)
#   15000000 + 100*Y + X   common event Y's self variable X   (X: 0-99;
#                          5-9 is the string quintet, everything else numeric)
#   1600000 + X            this common event's self variable X
#   2000000 + X            variable X (a flat array; the editor's "予備変数"
#                          reserve banks are just 2000000 + 100000*bank + X,
#                          which collapses to the same flat addressing)
#   3000000 + X            string variable X
#   8000000 + X            a random integer in 0..X (not a variable at all --
#                          the value-reference trick doubles as a pseudo-RNG
#                          call)
#   9000000 + X            system variable X
#   9900000 + X            system string X
#   1000000000 + AA*1000000 + BBBB*100 + CC   user DB type AA / data BBBB / field CC
#   1100000000 + ...                          changeable DB, same digit grouping
#   1300000000 + ...                          system DB, same digit grouping
#
# Not implemented (decoded but rejected with a clear, once-per-kind log
# rather than silently returning 0 -- see AGENTS.md's error-handling rule):
# the 9100000/9180000/9190000 event/hero position get-or-set range, which
# reads or *moves* a character through the same mechanism and needs the map
# runtime this gem does not drive yet.
module Wolf
  module ValueRef
    LITERAL_MAX = 999_999
    MAP_EVENT_SELF_BASE = 1_000_000
    MAP_EVENT_SELF_STRIDE = 10
    THIS_MAP_EVENT_SELF_BASE = 1_100_000
    THIS_MAP_EVENT_SELF_END = 1_100_010
    VARIABLE_BASE = 2_000_000
    STRING_BASE = 3_000_000
    STRING_END = 4_000_000
    RANDOM_BASE = 8_000_000
    RANDOM_END = 9_000_000
    SYSTEM_VARIABLE_BASE = 9_000_000
    SYSTEM_VARIABLE_END = 9_100_000
    EVENT_POSITION_BASE = 9_100_000
    EVENT_POSITION_END = 9_180_000
    PARTY_POSITION_BASE = 9_180_000
    PARTY_POSITION_END = 9_190_000
    THIS_EVENT_POSITION_BASE = 9_190_000
    THIS_EVENT_POSITION_END = 9_200_000
    SYSTEM_STRING_BASE = 9_900_000
    SYSTEM_STRING_END = 10_000_000
    COMMON_EVENT_SELF_BASE = 15_000_000
    COMMON_EVENT_SELF_STRIDE = 100
    COMMON_EVENT_SELF_END = 1_000_000_000
    THIS_COMMON_EVENT_SELF_BASE = 1_600_000
    THIS_COMMON_EVENT_SELF_END = 1_600_100
    DB_USER_BASE = 1_000_000_000
    DB_CHANGEABLE_BASE = 1_100_000_000
    DB_SYSTEM_BASE = 1_300_000_000
    DB_BAND = 100_000_000
    DB_TYPE_UNIT = 1_000_000
    DB_DATA_UNIT = 100

    # Common event self variables 5-9 (of each 100-slot bank) are string-only;
    # every other slot is numeric. Map event self variables (10 slots) are
    # treated as all-numeric -- the manual does not document a string subset
    # for them the way it does for common events, so none is assumed here.
    # Plain bounds rather than a Range#cover?/#include? check: mruby-wolf
    # does not (and should not need to) depend on mruby-range-ext just for
    # this, and per AGENTS.md's documented per-gem isolation trap (the same
    # one that made mruby-sprintf an explicit add_dependency), relying on a
    # method some other gem happens to add to a shared core class is fragile
    # across build configs.
    COMMON_EVENT_SELF_STRING_MIN = 5
    COMMON_EVENT_SELF_STRING_MAX = 9

    # Decodes a raw command argument into a tagged reference. Returns
    # `[:literal, value]` or one of the tagged forms `vars.rb`'s `VarStore`
    # understands (`:map_event_self`, `:this_map_event_self`, `:variable`,
    # `:string`, `:random`, `:system_variable`, `:system_string`,
    # `:common_event_self`, `:this_common_event_self`, `:db`) or
    # `[:unsupported, value]` for the position get/set range.
    def self.decode(value)
      return [:literal, value] if value >= -LITERAL_MAX && value <= LITERAL_MAX
      return [:literal, value] if value < 0

      if value >= MAP_EVENT_SELF_BASE && value < THIS_MAP_EVENT_SELF_BASE
        off = value - MAP_EVENT_SELF_BASE
        event_id, idx = off.divmod(MAP_EVENT_SELF_STRIDE)
        return [:map_event_self, event_id, idx]
      end
      if value >= THIS_MAP_EVENT_SELF_BASE && value < THIS_MAP_EVENT_SELF_END
        return [:this_map_event_self, value - THIS_MAP_EVENT_SELF_BASE]
      end
      if value >= THIS_COMMON_EVENT_SELF_BASE && value < THIS_COMMON_EVENT_SELF_END
        return [:this_common_event_self, value - THIS_COMMON_EVENT_SELF_BASE]
      end
      if value >= VARIABLE_BASE && value < STRING_BASE
        return [:variable, value - VARIABLE_BASE]
      end
      if value >= STRING_BASE && value < STRING_END
        return [:string, value - STRING_BASE]
      end
      if value >= RANDOM_BASE && value < RANDOM_END
        return [:random, value - RANDOM_BASE]
      end
      if value >= SYSTEM_VARIABLE_BASE && value < SYSTEM_VARIABLE_END
        return [:system_variable, value - SYSTEM_VARIABLE_BASE]
      end
      if value >= EVENT_POSITION_BASE && value < EVENT_POSITION_END
        return [:unsupported, value]
      end
      if value >= PARTY_POSITION_BASE && value < PARTY_POSITION_END
        return [:unsupported, value]
      end
      if value >= THIS_EVENT_POSITION_BASE && value < THIS_EVENT_POSITION_END
        return [:unsupported, value]
      end
      if value >= SYSTEM_STRING_BASE && value < SYSTEM_STRING_END
        return [:system_string, value - SYSTEM_STRING_BASE]
      end
      if value >= DB_USER_BASE && value < DB_USER_BASE + DB_BAND
        return decode_db(:user, value - DB_USER_BASE)
      end
      if value >= DB_CHANGEABLE_BASE && value < DB_CHANGEABLE_BASE + DB_BAND
        return decode_db(:changeable, value - DB_CHANGEABLE_BASE)
      end
      if value >= DB_SYSTEM_BASE && value < DB_SYSTEM_BASE + DB_BAND
        return decode_db(:system, value - DB_SYSTEM_BASE)
      end
      # Falls after every named band but below the DB range: the common event
      # self-variable band (15000000+100*Y+X), which has no documented upper
      # bound -- it simply has to end before 1000000000 (DB) starts.
      if value >= COMMON_EVENT_SELF_BASE && value < COMMON_EVENT_SELF_END
        off = value - COMMON_EVENT_SELF_BASE
        common_id, idx = off.divmod(COMMON_EVENT_SELF_STRIDE)
        return [:common_event_self, common_id, idx]
      end
      [:unsupported, value]
    end

    def self.decode_db(section, offset)
      field_id = offset % DB_DATA_UNIT
      data_id = (offset / DB_DATA_UNIT) % (DB_TYPE_UNIT / DB_DATA_UNIT)
      type_id = offset / DB_TYPE_UNIT
      [:db, section, type_id, data_id, field_id]
    end

    def self.common_event_self_string?(index)
      index >= COMMON_EVENT_SELF_STRING_MIN && index <= COMMON_EVENT_SELF_STRING_MAX
    end
  end

  # Backing storage for every variable/switch/string an event command can
  # touch, plus the reference resolution above. One VarStore per running
  # project; self-variable banks persist for the project's lifetime, indexed
  # by map/common event id, matching the editor's own semantics ("マップ
  # イベント0番のセルフ変数1の値を変更しても、他のマップイベントの
  # セルフ変数1は変化しません" -- help/01specifi.html's implicit-spec #2).
  class VarStore
    class UnsupportedRef < StandardError; end

    def initialize(project)
      @project = project
      @variables = Hash.new(0)
      @strings = Hash.new("")
      @system_variables = Hash.new(0)
      @system_strings = Hash.new("")
      @map_event_self = {}
      @common_event_self = {}
      # The common/map event whose commands are currently executing, so
      # "this event"-relative references (1100000+X, 1600000+X) resolve.
      # Interpreter#run sets these for the duration of one event's commands.
      @current_map_event_id = nil
      @current_common_event_id = nil
      @warned = {}
    end

    attr_accessor :current_map_event_id, :current_common_event_id

    def warn_once(key, message)
      return if @warned[key]
      @warned[key] = true
      $stderr.puts "[Wolf] #{message}"
    end

    def map_event_self_bank(event_id)
      @map_event_self[event_id] ||= Hash.new(0)
    end

    def common_event_self_bank(common_id)
      @common_event_self[common_id] ||= Hash.new(0)
    end

    # Reads `raw` (an int32 command argument) as a number. Self-variable
    # banks (map/common event) are untyped storage a real project can (and,
    # per Database(250)'s own real command dumps, sometimes does) write a
    # string into via one code path and read as a number via another --
    # coerced defensively here (see #coerce_number) rather than handed
    # straight to a caller that assumes an Integer, the same "log rather
    # than guess" rule the string/system_string branch below already
    # follows for a slot whose *address* (not its current runtime value)
    # says it is a string.
    def number(raw)
      kind, *rest = ValueRef.decode(raw)
      case kind
      when :literal then rest[0]
      when :variable then coerce_number(kind, raw, @variables[rest[0]])
      when :system_variable then coerce_number(kind, raw, @system_variables[rest[0]])
      when :random
        max = rest[0]
        max <= 0 ? 0 : rand(max + 1)
      when :map_event_self then coerce_number(kind, raw, map_event_self_bank(rest[0])[rest[1]])
      when :this_map_event_self
        require_current_map_event!
        coerce_number(kind, raw, map_event_self_bank(@current_map_event_id)[rest[0]])
      when :common_event_self then common_self_number(rest[0], rest[1])
      when :this_common_event_self
        require_current_common_event!
        common_self_number(@current_common_event_id, rest[0])
      when :db then db_number(rest[0], rest[1], rest[2], rest[3])
      when :string, :system_string
        warn_once("num-from-string-#{kind}", "reading a string reference (#{raw}) as a number; treating as 0")
        0
      else
        warn_once("num-unsupported-#{kind}", "unsupported numeric reference kind #{kind} (raw #{raw}); treating as 0")
        0
      end
    end

    # True if `raw` addresses a string-typed slot -- a literal string
    # variable, a system string, or a common-event self-variable in the
    # "string quintet" (the same kinds #string reads/#set_string writes).
    # Used by SaveVariable(222)/LoadVariable(221) to pick number vs.
    # string for a variable-ref field without #string's own defensive
    # "reading a literal as a string" warning on a plain numeric ref.
    def string_ref?(raw)
      kind, *rest = ValueRef.decode(raw)
      case kind
      when :string, :system_string then true
      when :common_event_self then ValueRef.common_event_self_string?(rest[1])
      when :this_common_event_self then ValueRef.common_event_self_string?(rest[0])
      else false
      end
    end

    # Reads `raw` as a string. See #number's own comment on why the untyped
    # self-variable banks are coerced defensively rather than trusted.
    def string(raw)
      kind, *rest = ValueRef.decode(raw)
      case kind
      when :string then @strings[rest[0]]
      when :system_string then @system_strings[rest[0]]
      when :common_event_self then common_self_string(rest[0], rest[1])
      when :this_common_event_self
        require_current_common_event!
        common_self_string(@current_common_event_id, rest[0])
      when :db then db_string(rest[0], rest[1], rest[2], rest[3])
      when :literal
        warn_once("str-from-literal", "reading a literal number (#{raw}) as a string; treating as \"\"")
        ""
      else
        warn_once("str-unsupported-#{kind}", "unsupported string reference kind #{kind} (raw #{raw}); treating as \"\"")
        ""
      end
    end

    # Writes `value` (a number) to the slot `raw` refers to.
    def set_number(raw, value)
      kind, *rest = ValueRef.decode(raw)
      case kind
      when :variable then @variables[rest[0]] = value
      when :system_variable then @system_variables[rest[0]] = value
      when :map_event_self then map_event_self_bank(rest[0])[rest[1]] = value
      when :this_map_event_self
        require_current_map_event!
        map_event_self_bank(@current_map_event_id)[rest[0]] = value
      when :common_event_self then set_common_self_number(rest[0], rest[1], value)
      when :this_common_event_self
        require_current_common_event!
        set_common_self_number(@current_common_event_id, rest[0], value)
      when :literal
        warn_once("write-literal", "command writes to a literal (#{raw}); ignoring")
      else
        warn_once("write-unsupported-#{kind}", "unsupported numeric write target #{kind} (raw #{raw}); ignoring")
      end
    end

    # Writes `value` (a String) to the slot `raw` refers to.
    def set_string(raw, value)
      kind, *rest = ValueRef.decode(raw)
      case kind
      when :string then @strings[rest[0]] = value
      when :system_string then @system_strings[rest[0]] = value
      when :common_event_self then set_common_self_string(rest[0], rest[1], value)
      when :this_common_event_self
        require_current_common_event!
        set_common_self_string(@current_common_event_id, rest[0], value)
      when :literal
        warn_once("write-literal-str", "command writes to a literal (#{raw}); ignoring")
      else
        warn_once("write-unsupported-str-#{kind}", "unsupported string write target #{kind} (raw #{raw}); ignoring")
      end
    end

    private

    def require_current_map_event!
      return if @current_map_event_id
      raise UnsupportedRef, "\"this map event\" self-variable reference outside a running map event"
    end

    def require_current_common_event!
      return if @current_common_event_id
      raise UnsupportedRef, "\"this common event\" self-variable reference outside a running common event"
    end

    def common_self_number(common_id, index)
      warn_once("common-self-type-#{index}", "reading common event self-var #{index} as a number, but it is the string quintet") if ValueRef.common_event_self_string?(index)
      v = common_event_self_bank(common_id)[index]
      coerce_number(:common_event_self, index, v)
    end

    def common_self_string(common_id, index)
      unless ValueRef.common_event_self_string?(index)
        warn_once("common-self-strtype-#{index}", "reading common event self-var #{index} as a string, but it is numeric")
      end
      v = common_event_self_bank(common_id)[index]
      v.is_a?(String) ? v : ""
    end

    def set_common_self_number(common_id, index, value)
      common_event_self_bank(common_id)[index] = value
    end

    def set_common_self_string(common_id, index, value)
      common_event_self_bank(common_id)[index] = value
    end

    def db_type(section, type_id)
      db = @project.databases[section]
      db && db[type_id]
    end

    def db_number(section, type_id, data_id, field_id)
      t = db_type(section, type_id)
      v = t && t.value(data_id, field_id)
      v.is_a?(Integer) ? v : 0
    end

    def db_string(section, type_id, data_id, field_id)
      t = db_type(section, type_id)
      v = t && t.value(data_id, field_id)
      v.is_a?(String) ? v : ""
    end

    # A variable/self-variable bank slot's stored value, defensively typed:
    # every bank is a plain untyped Hash (`set_number`/`set_string` share
    # the same slot), so a project that writes one type into a slot and
    # later reads it as the other -- Database(250)'s own real command dumps
    # show a common event doing exactly this across its own self-vars, once
    # the numeric-field and string-field read/write calls for the same
    # common event's own scratch slots are replayed in isolation -- must not
    # hand a caller (fold32, `apply_assign_op`'s arithmetic, a DBType index)
    # something it cannot use.
    def coerce_number(kind, raw, v)
      return v if v.is_a?(Integer)
      warn_once("num-wrong-type-#{kind}", "#{kind} reference (#{raw}) holds #{v.inspect}, not a number; treating as 0")
      0
    end
  end
end
