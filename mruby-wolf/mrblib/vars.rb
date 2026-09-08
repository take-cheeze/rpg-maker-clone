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
#   9100000 + 10*Y + X     map event Y's own position/facing field X (get or
#                          set -- see Wolf::Interpreter#resolve_position_ref)
#   9180000 + 10*Y + X     the hero's (Y=0) or a companion's (Y=1..5) own
#                          position/facing field X
#   9190000 + X            this map event's own position/facing field X
#   9900000 + X            system string X
#   1000000000 + AA*1000000 + BBBB*100 + CC   user DB type AA / data BBBB / field CC
#   1100000000 + ...                          changeable DB, same digit grouping
#   1300000000 + ...                          system DB, same digit grouping
#
# The position ranges' own field X (help/06valueget.html's own ※1) is only
# partly implemented -- X=0/1 (plain tile X/Y), 2/3 (precise X/Y, read-only:
# the same half-tile formula SetVariableEx(124)'s own Character/PreciseX/Y
# field already uses, get-only there too) and 6 (numpad-convention facing)
# read or write a real position; X=4/5/7/8/9 (pixel height, shadow number,
# pixel offset X/Y, character-chip image) are decoded but rejected with a
# clear, once-per-kind log rather than silently returning 0 (see AGENTS.md's
# error-handling rule) -- each needs state (sub-tile pixel position, a
# shadow graphic, ...) this reader has never tracked for any character.
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
    # `:common_event_self`, `:this_common_event_self`, `:db`,
    # `:event_position`, `:party_position`, `:this_event_position`) or
    # `[:unsupported, value]` for anything past the last named band.
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
        off = value - EVENT_POSITION_BASE
        event_id, field = off.divmod(10)
        return [:event_position, event_id, field]
      end
      if value >= PARTY_POSITION_BASE && value < PARTY_POSITION_END
        off = value - PARTY_POSITION_BASE
        who, field = off.divmod(10)
        return [:party_position, who, field]
      end
      if value >= THIS_EVENT_POSITION_BASE && value < THIS_EVENT_POSITION_END
        return [:this_event_position, value - THIS_EVENT_POSITION_BASE]
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
      # The map `#map_event_self_bank` keys its own banks by, alongside
      # each bank's own event id -- kept in sync by `Wolf::Interpreter#
      # current_map_id=`'s own setter, not written here directly. `nil`
      # until the first real map load, or in a context with no real map
      # load at all (this class's own test suite): every map event on that
      # one implicit map still keys uniquely off its own id there, same as
      # before this existed.
      @current_map_id = nil
      # Wolf::Interpreter#initialize sets this to itself, the seam
      # `#position_number`/`#set_position_number` (the 9100000/9180000/
      # 9190000 position-addressing ranges) resolve a live character
      # position through -- see `Interpreter#resolve_position_ref`'s own
      # comment. `nil` in a context with no real Interpreter at all (most
      # of this class's own test suite, which constructs a bare VarStore):
      # those ranges then log once and return 0/no-op, the same graceful
      # "not available in this context" degradation `#number`'s own
      # `:string`/`:system_string` branch already uses.
      @interpreter = nil
      @warned = {}
    end

    attr_accessor :current_map_event_id, :current_common_event_id, :current_map_id, :interpreter

    def warn_once(key, message)
      return if @warned[key]
      @warned[key] = true
      $stderr.puts "[Wolf] #{message}"
    end

    # SaveLoad(220)'s own "Save"/"Load" seam: the four flat banks a real
    # save round-trips through this reader (regular/system variables and
    # strings) -- explicitly *not* the self-variable banks, the database,
    # or anything else `Wolf::SaveData`'s own module comment already
    # documents as out of scope for this reader's own deliberately partial
    # save format (see docs/adr for the full save/load command). Each
    # Hash's own default value (0/`""`) round-trips through `Marshal`
    # unchanged (mruby-marshal's own `ifnone` tag), so `#restore` only
    # needs to fall back to a fresh default-having Hash for a snapshot
    # from before a key existed at all, not for an untouched slot within
    # one that does.
    def snapshot
      { variables: @variables, strings: @strings, system_variables: @system_variables, system_strings: @system_strings }
    end

    def restore(snapshot)
      @variables = snapshot[:variables] || Hash.new(0)
      @strings = snapshot[:strings] || Hash.new("")
      @system_variables = snapshot[:system_variables] || Hash.new(0)
      @system_strings = snapshot[:system_strings] || Hash.new("")
    end

    # Keyed by `[current_map_id, event_id]`, not `event_id` alone -- two
    # different maps' own event id spaces both start from small numbers
    # like 0/1/2 and would otherwise collide, the exact same reasoning
    # `Wolf::Interpreter#event_position`'s own identical fix (ADR 0089)
    # already applies to a map event's runtime *position*; this is its
    # counterpart for a map event's own self-variable *bank*.
    def map_event_self_bank(event_id)
      @map_event_self[[current_map_id, event_id]] ||= Hash.new(0)
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
      when :event_position then position_number(:event_position, rest[0], rest[1])
      when :party_position then position_number(:party_position, rest[0], rest[1])
      when :this_event_position then position_number(:this_event_position, nil, rest[0])
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
      when :event_position then set_position_number(:event_position, rest[0], rest[1], value)
      when :party_position then set_position_number(:party_position, rest[0], rest[1], value)
      when :this_event_position then set_position_number(:this_event_position, nil, rest[0], value)
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

    # help/06valueget.html's own ※1 field table, `X`'s shared meaning across
    # all three position-addressing ranges. Only the fields this reader can
    # actually answer without inventing new state: 0/1 plain tile X/Y, 2/3
    # precise X/Y (get-only -- the exact half-tile formula SetVariableEx
    # (124)'s own Character/PreciseX/Y field already uses and cross-
    # validates, get-only there too), 6 numpad-convention facing (get/set --
    # the same down/left/right/up -> 2/4/6/8 table SetVariableEx(124)'s own
    # `CHAR_DIRECTION_NUMPAD` already established, matching every other
    # maker in this codebase's own numpad direction convention). 4 (pixel
    # height), 5 (shadow number), 7/8
    # (pixel offset X/Y) and 9 (character-chip image, a string field this
    # numeric path never reaches) are all logged and left alone -- each
    # needs sub-tile pixel state or a shadow/image concept this reader has
    # never tracked for any character, map event or party member alike.
    POSITION_FIELD_X = 0
    POSITION_FIELD_Y = 1
    POSITION_FIELD_PRECISE_X = 2
    POSITION_FIELD_PRECISE_Y = 3
    POSITION_FIELD_DIRECTION = 6
    POSITION_DIRECTION_NUMPAD = { down: 2, left: 4, right: 6, up: 8 }.freeze
    # The plain inverse of the table above, spelled out rather than built
    # with `Hash#invert` (an mruby-hash-ext method -- this gem does not
    # depend on that gem, the exact per-gem-isolation trap AGENTS.md and
    # this file's own mrbgem.rake comment already document elsewhere).
    POSITION_NUMPAD_DIRECTION = { 2 => :down, 4 => :left, 6 => :right, 8 => :up }.freeze
    # `kind`'s own plain-English label for a log line -- spelled out rather
    # than `kind.to_s.tr("_", " ")`/`#gsub`, neither of which this build's
    # mruby actually provides (`String#tr`/`#gsub` are full-CRuby-only
    # here, confirmed by grepping every vendored gem's own source).
    POSITION_KIND_LABEL = {
      event_position: "event position",
      party_position: "party/hero position",
      this_event_position: "this event's own position",
    }.freeze

    def position_number(kind, who, field)
      label = POSITION_KIND_LABEL[kind] || kind.to_s
      unless @interpreter
        warn_once("position-no-runtime-#{kind}", "#{label} query with no interpreter attached; treating as 0")
        return 0
      end
      pos, = @interpreter.resolve_position_ref(kind, who)
      unless pos
        warn_once("position-none-#{kind}-#{who}", "#{label} query (who=#{who.inspect}): nothing there; treating as 0")
        return 0
      end
      case field
      when POSITION_FIELD_X then pos[:x]
      when POSITION_FIELD_Y then pos[:y]
      when POSITION_FIELD_PRECISE_X then pos[:x] * 2
      when POSITION_FIELD_PRECISE_Y then pos[:y] * 2 - 1
      when POSITION_FIELD_DIRECTION then POSITION_DIRECTION_NUMPAD[pos[:direction]] || 0
      else
        warn_once("position-field-#{kind}-#{field}", "#{label} field #{field} is not implemented yet; treating as 0")
        0
      end
    end

    # Assigning to the "position" reference is documented as moving the
    # character at its own configured speed ("設定された移動速度で"), not
    # instantly -- this reader has no gradual/sub-tile movement model at
    # all (every other instant-scene-change command here, Teleport(130)
    # included, already snaps rather than animates), so this snaps here
    # too rather than inventing one just for this seam.
    def set_position_number(kind, who, field, value)
      label = POSITION_KIND_LABEL[kind] || kind.to_s
      unless @interpreter
        warn_once("position-write-no-runtime-#{kind}", "#{label} write with no interpreter attached; ignoring")
        return
      end
      pos, writeback = @interpreter.resolve_position_ref(kind, who)
      unless pos
        warn_once("position-write-none-#{kind}-#{who}", "#{label} write (who=#{who.inspect}): nothing there; ignoring")
        return
      end
      case field
      when POSITION_FIELD_X then pos[:x] = value
      when POSITION_FIELD_Y then pos[:y] = value
      when POSITION_FIELD_DIRECTION
        dir = POSITION_NUMPAD_DIRECTION[value]
        unless dir
          warn_once("position-write-direction-#{value}", "#{label} direction write: #{value} is not a numpad 2/4/6/8 facing; ignoring")
          return
        end
        pos[:direction] = dir
      else
        warn_once("position-write-field-#{kind}-#{field}", "#{label} field #{field} is not implemented yet; ignoring")
        return
      end
      writeback&.call(pos)
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
