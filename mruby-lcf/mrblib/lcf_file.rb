# The LCF file classes (LCF::Database/.ldb, LCF::MapTree/.lmt,
# LCF::MapUnit/.lmu, LCF::SaveData/.lsd) and their shared LCF::File base.
#
# Split out of schema.rb (docs/adr/0109/0123): these are real, hand-written
# behavior -- #initialize's read path, #to_lcf's write path, #rpg2003?,
# #terminate_root? -- not schema *data*, so they were never something
# gen_schema_blob.rb's data-only generator should have owned. schema.rb
# itself is entirely replaced by a generated blob (mrbgem.rake's own
# spec.rbfiles swap); keeping these classes in that same file meant they
# silently stopped compiling into every target the moment that swap
# landed, since nothing carried them into the replacement.
module LCF
  class File
    def initialize io = nil
      # No stream builds an empty, writable file from scratch: an empty root of
      # the schema's type, ready to populate via #[]= and serialise with #to_lcf
      # / #save_to. Multi-section (Array-schema) files are not yet buildable.
      if io.nil?
        raise 'section-based file construction not implemented' if schema.is_a? Array
        @root = LCF.const_get(schema[:type]).new('', schema)
        return
      end
      @io = io
      h_len = LCF.read_ber io
      h = io.read h_len
      raise "Invalid header: #{h} (expected: #{header})" if h != header
      if schema.is_a? Array
        sections = LCF::Sections.new
        schema.each { |s| sections.add s[:name], LCF.read_section(io, s) }
        @root = sections
      else
        @root = LCF.const_get(schema[:type]).new io, schema
      end
    end

    def header; raise end
    def schema; raise end

    # Whether the root chunk list ends with a trailing 0x00 terminator.
    # `.lsd` (SaveData) and `.ldb` (Database) do not -- confirmed by a
    # byte-exact round-trip of a genuine RPG_RT.ldb and Save01.lsd with no
    # appended byte -- so this defaults to false. `.lmu` (MapUnit) is the one
    # exception: overridden below.
    def terminate_root?; false end

    # Serialise the whole file back to bytes: the BER-length-prefixed header
    # string followed by the root object's own serialisation. The inverse of
    # #initialize; a file read and written back without edits reproduces it
    # byte-for-byte. Multi-section (Array-schema) files are not yet writable.
    def to_lcf
      raise 'section-based file serialization not implemented' if schema.is_a? Array
      root = @root.is_a?(LCF::Array1D) ? @root.to_lcf(terminate_root?) : @root.to_lcf
      LCF.write_ber(header.bytesize) + LCF.binstr(header) + LCF.binstr(root)
    end

    # Write #to_lcf to a path (binary). Uses ::File since LCF::File shadows it.
    def save_to path
      ::File.open(path, 'wb') { |f| f.write to_lcf }
    end

    def method_missing sym, *args
      # Use __send__ rather than send: some mruby builds do not expose Kernel#send
      # on objects that define their own method_missing (Array1D / Sections),
      # which routes `send` into method_missing and breaks field access.
      @root.__send__ sym, *args
    end

    def respond_to_missing? sym, include_private = false
      @root.respond_to?(sym) || super
    end
  end

  class Database < File
    def header; "LcfDataBase" end
    def schema; LCF::Schema::DATABASE end

    # RPG Maker 2003 databases carry a Classes (職業) section, chunk 30, that
    # RPG2000 never writes. Its presence is the file-level signal that a project
    # was authored in 2003, independent of the compile-time LCF::MODE default.
    def rpg2003?
      @root.key? 30
    end

    # Editor edition that wrote this database: 2003 or 2000.
    def maker
      rpg2003? ? 2003 : 2000
    end
  end

  class MapTree < File
    def header; "LcfMapTree" end
    def schema; LCF::Schema::MAP_TREE end
  end

  class MapUnit < File
    def header; "LcfMapUnit" end
    def schema; LCF::Schema::MAP_UNIT end

    # Unlike .lsd/.ldb, a genuine .lmu carries a trailing 0x00 root
    # terminator -- confirmed by round-tripping real Nepheshel Map*.lmu
    # files: every one came out exactly one byte short without this, and
    # byte-identical to the original with it. Confirmed to matter at
    # runtime too: a genuine RPG_RT.exe hangs on a black screen loading a
    # map file written without this byte, and loads it correctly once
    # appended.
    def terminate_root?; true end
  end

  class SaveData < File
    def header; "LcfSaveData" end
    def schema; LCF::Schema::SAVE_DATA end
  end
end
