# frozen_string_literal: true

# ROM_CLASS_CELLS (bc2cpp's program_class_slots.rb): the owner-class cells a wio libmruby built with
# BC2CPP_ROM_CLASS_CELLS leaves to its link, as C that rom_graph.bash compiles into rom_graph.o.
#   ruby rom_graph_cells.rb RUNTIME_HEADER_DIR [GRAPH.c] > cells.c
# An owner whose path is a named class of GRAPH.c gets a const cell holding its ROM class; every other owner, and every
# owner when there is no graph, gets a RAM cell its lookup fills. The dump keys a named class by the path that resolves
# to it, which is the lookup the cell stands for. A RAM class (rom_graph_ram_classes.h) is in it too: that list is about
# its constant table, and its RClass is const all the same.
dir, graph = ARGV
abort 'usage: rom_graph_cells.rb RUNTIME_HEADER_DIR [GRAPH.c]' unless dir

NAMED = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

# The dump's `/* INDEX KEY mt:... */` line before each class of mrb_rom_classes_, and the first word of its const
# tables (ivd_N.v) that holds class INDEX: a const cell already in the graph (its outer's constant, its own
# __outer__), so a class with one needs no cell of its own.
rom = {}
word = {}
if graph
  table = nil
  at = 0
  File.foreach(graph) do |line|
    if (m = /\Astatic const struct \{ mrb_value v\[\d+\]; mrb_sym k\[\d+\]; \} (ivd_\d+) = \{\{\n\z/.match(line))
      table = m[1]
      at = 0
    elsif table && line.start_with?('}, {')
      table = nil
    elsif table
      k = line[/\A  MRB_ROM_OBJV\(R\((\d+)\)\),\n\z/, 1]
      word[k.to_i] ||= "&#{table}.v[#{at}]" if k
      at += 1
    elsif (m = %r{\A  /\* (\d+) (\S+) mt:}.match(line))
      rom[m[2]] = m[1].to_i if NAMED.match?(m[2])
    end
  end
  abort "rom_graph_cells: #{graph} names no class" if rom.empty?
end

out = +"// ROM_CLASS_CELLS: written by scripts/wio/rom_graph_cells.rb.\n"
out << (graph ? "#include \"#{File.expand_path(graph)}\"\n" : "#include <mruby.h>\n#include <mruby/rom_graph.h>\n")
# A graph word is read as the cell's RClass*: word boxing keeps an object value as its pointer (MRB_ROM_OBJV).
out << "_Static_assert(sizeof(mrb_value) == sizeof(struct RClass*), \"ROM_CLASS_CELLS reads a value word as a class\");\n" if graph
Dir[File.join(dir, 'bc2cpp_pw_classes_*.owners')].sort.each do |file|
  d = File.basename(file)[/\Abc2cpp_pw_classes_(\h+)\.owners\z/, 1] or next
  owners = File.read(file).lines.map(&:chomp)
  in_rom = owners.map { |path| rom[path] }
  roms = in_rom.compact.uniq.reject { |k| word[k] }
  rams = owners.each_index.reject { |i| in_rom[i] }
  cells = owners.each_index.map do |i|
    k = in_rom[i]
    cell = if k.nil? then "&ram_#{d}[#{rams.index(i)}]"
           elsif word[k] then "(struct RClass**)#{word[k]}"
           else "(struct RClass**)&rom_#{d}[#{roms.index(k)}]"
           end
    "  #{cell},  /* #{owners[i]} */\n"
  end
  cells = ["  &ram_#{d}[0],\n"] if owners.empty?
  out << "static struct RClass *ram_#{d}[#{[rams.size, 1].max}];\n"
  out << "static struct RClass *const rom_#{d}[#{[roms.size, 1].max}] = {#{roms.map { |k| "R(#{k})" }.join(', ')}};\n" unless roms.empty?
  out << "struct RClass **const bc2cpp_pw_class_cells_#{d}[#{[owners.size, 1].max}] = {\n#{cells.join}};\n"
  out << "void bc2cpp_pw_class_reset_#{d}(void) {\n" \
         "  for (unsigned i = 0; i < sizeof(ram_#{d}) / sizeof(ram_#{d}[0]); i++) ram_#{d}[i] = NULL;\n}\n"
  # A ROM cell is the class only in the VM that runs on this graph (mruby/rom_graph.h: one state at a time).
  out << "void bc2cpp_pw_class_claim_#{d}(mrb_state *M) {\n"
  out << if in_rom.none?
           "  (void)M;\n"
         else
           "  if (!mrb_rom_graph_active(M)) mrb_bug(M, \"ROM_CLASS_CELLS: this VM does not run on the class graph its cells hold\");\n"
         end
  out << "}\n"
  warn "rom_graph_cells: #{d}: #{in_rom.compact.uniq.size} ROM classes (#{roms.size} cells of their own), #{rams.size} RAM cells"
end
print out
