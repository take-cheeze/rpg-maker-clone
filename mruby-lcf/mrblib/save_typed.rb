# The checked, typed read path for a Save<N>.lsd (docs/adr/0400).
#
# Every saved field is read through one typed accessor, generated from
# LCF::Schema by mruby-lcf/gen_save_typed_accessors.rb into
# save_typed_accessors.rb (do not edit that file). This file is the hand-written
# part those accessors call: the type check, the record base class, and the
# frame shape Game::State reads the event execution stack into.
#
# LCF::SaveData#initialize runs the whole tree through SaveTyped::Save#check!
# when a save is read, so a save whose bytes do not match the type its schema
# declares raises LCF::SaveTypeError there, naming the field. The caller
# (RPG2k#load_save_state) logs that reason and treats the slot as empty -- a
# save is never half-loaded.
#
# Loads before save_typed_accessors.rb (mrblib files load sorted; "." sorts
# before "_"), which subclasses Record defined here.

module LCF
  # A save decoded but a field does not match its declared type. The message
  # names the field by its path, e.g. "Save.hero.through: invalid bool size: 2".
  class SaveTypeError < StandardError; end

  module SaveTyped
    # Whether +v+ is a value the schema type +type+ decodes to. These are the
    # Ruby classes LCF.to_rb produces for each type in the save schema.
    def self.fits? type, v
      case type
      when :int, :uint8 then v.is_a?(Integer)
      when :bool then v == true || v == false
      when :double then v.is_a?(Float)
      when :string then v.is_a?(String)
      when :Array1D then v.is_a?(LCF::Array1D)
      when :Array2D then v.is_a?(LCF::Array2D)
      when :int16_array then v.is_a?(Array) || v.is_a?(Hash)
      when :int8_array, :int32_array, :bool_array, :event, :move_commands
        v.is_a?(Array)
      else false
      end
    end

    # The decoded value of field +id+ of record +rec+, checked against +type+.
    # An absent field reads its schema default (LCF::Array1D#[]); a field absent
    # with no default is nil, which is valid for it. A decode failure or a
    # mismatched class raises SaveTypeError naming +path+.
    def self.read rec, id, type, path
      begin
        v = rec[id]
      rescue StandardError => e
        raise SaveTypeError, "#{path}: #{e.message}"
      end
      return nil if v.nil?
      unless fits?(type, v)
        raise SaveTypeError, "#{path}: expected #{type}, got #{v.class}"
      end
      v
    end

  # Base of every generated typed record: a table's Array1D (or one row of an
  # Array2D) plus the path naming it in error messages.
  class Record
    attr_reader :rec, :path

    def initialize rec, path
      @rec = rec
      @path = path
    end

    def read id, type, name
      SaveTyped.read(@rec, id, type, "#{@path}.#{name}")
    end

    # A nested Array1D field, as its own checked record (nil when absent).
    def table id, klass, name
      r = read(id, :Array1D, name)
      return nil if r.nil?
      child = klass.new(r, "#{@path}.#{name}")
      child.check!
      child
    end

    # A nested Array2D field: the table, with every row checked as +klass+.
    def rows id, klass, name
      arr = read(id, :Array2D, name)
      return nil if arr.nil?
      arr.each { |i, row| klass.new(row, "#{@path}.#{name}[#{i}]").check! }
      arr
    end
  end
  end
end

module LCF
  module SaveTyped
    # One saved event-execution frame (chunk 113/114's stack row), as the Hash
    # shape Game::Interpreter#restore_call_stack consumes:
    #
    #   { commands: Array<LCF::EventCommand>, current_command: Integer,
    #     event_id: Integer, triggered_by_decision_key: true | false }
    #
    # Each value is a typed accessor's, so a frame that reaches restore_call_stack
    # has been checked against the schema (its command list included).
    class EventExecFrame < Record
      def frame
        { commands: save_commands,
          current_command: save_current_command,
          event_id: save_event_id,
          triggered_by_decision_key: save_triggered_by_decision_key }
      end
    end

    # The execution state of chunk 113 (foreground event) or 114 (common event).
    # Its stack is read and checked separately from the rest of the state (see
    # UNCHECKED in gen_save_typed_accessors.rb): a stack that does not decode
    # raises here, and Game::State.read_event_exec_frames turns that into "resume
    # without it", the behaviour the chunk has always had.
    class EventExecState < Record
      # The frames outermost first, or nil when the stack is absent or empty.
      def frames
        arr = save_stack
        return nil if arr.nil?
        out = []
        arr.each { |i, row| out.push(EventExecFrame.new(row, "#{path}.stack[#{i}]").frame) }
        out.empty? ? nil : out
      end
    end
  end
end
