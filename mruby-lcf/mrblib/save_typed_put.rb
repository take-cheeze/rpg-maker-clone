# The write side of the typed save records: the one helper the
# generated writers in save_typed_setters.rb call. Loads between
# save_typed_accessors.rb and save_typed_setters.rb (mrblib files load sorted).
#
# A writer checks the value's class against the field's schema type (read from the
# record's schema, not repeated per writer), then stores
# it through LCF::Array1D#[]=, which encodes by the schema (LCF.encode). The write
# never has an encoder of its own, so the bytes are exactly those of
# `array1d[id] = value`. Not shipped on wio (mrbgem.rake).

module LCF
  module SaveTyped
    # Whether +v+ may be stored in a field of schema type +type+. The read-side
    # classes (SaveTyped.fits?), plus what the encoder accepts beyond them: an
    # Integer for a :double, a typed record for a nested table, and the named
    # Hash a read of an ordered :int16_array returns.
    def self.save_writable? type, v
      case type
      when :double then v.is_a?(Float) || v.is_a?(Integer)
      when :Array1D then v.is_a?(LCF::Array1D) || v.is_a?(Record)
      else fits?(type, v)
      end
    end

    class Record
      # Store +v+ as field +id+. The field's type and name come from the record's
      # schema (a Symbol name, e.g. :hero_name), so the generated writers carry
      # nothing but the id. nil drops the chunk, so the field reads its schema
      # default. A table assigned here, or a record read with `table`, is stored by
      # value: assign a table only once it is populated, or write through the
      # record the parent returned (it writes itself back to its parent). A nested
      # Array2D (`rows`) is stored the same way: assign it again after editing rows.
      # Returns +v+.
      def save_put id, v
        if v.nil?
          @rec.delete(id)
          @owner.save_put(@owner_id, @rec) if @owner
          return nil
        end
        elem = LCF.elements_of(@rec.schema)[id]
        type = elem[:type]
        unless SaveTyped.save_writable?(type, v)
          raise SaveTypeError, "#{@path}.#{elem[:name]}: expected #{type}, got #{v.class}"
        end
        stored = v
        stored = v.rec if v.is_a?(Record)
        if stored.is_a?(Hash)
          order = elem[:order]
          stored = order.map { |n| stored[n] || 0 }
        end
        @rec[id] = stored
        # A nested table is stored in its owner as the bytes it had when assigned
        # (LCF::Array1D#[]=), so a record read from a parent writes itself back up.
        @owner.save_put(@owner_id, @rec) if @owner
        v
      end
    end
  end
end
