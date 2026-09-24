#!/usr/bin/env ruby
# frozen_string_literal: true

# The methods of the wio closed world (mruby-rpg2k, mruby-lcf and mruby-rgss
# mrblib, as the wio build compiles them) that nothing can call, for
# strip_wio_unreachable_methods.rb. ADR 0218 has the soundness argument.
#
# A name is live when a call site, a Symbol/String literal, native C/C++, or a
# VM hook can dispatch to it, counting only code that is itself reachable (a
# worklist from the class bodies, native code and hooks). Every `def` of a
# name that never becomes live is unreachable.
#
#   ruby scripts/wio_unreachable_methods.rb                   # checked-in sources
#   ruby scripts/wio_unreachable_methods.rb --mrbc PATH       # plus bytecode cost
#   ruby scripts/wio_unreachable_methods.rb --manifest M.json --out dead.tsv
#
# The manifest form is the build step (build_config.rb's
# wio_strip_unreachable): {"world": {gem: [rbfile, ...]}, "ruby": [...],
# "native": [...]}, the build's real file lists.

require 'json'
require 'open3'
require 'prism'
require 'set'
require 'tmpdir'
require_relative 'strip_wio_unreachable_methods'
require_relative '../tools/bc2cpp/irep' # unescape_c_string
require_relative '../tools/bc2cpp/native_names'
require_relative '../tools/bc2cpp/compiled_gems'

module WioUnreachable
  ROOT = File.expand_path('..', __dir__)
  WORLD_GEMS = BC2CPP_CLOSED_WORLD_GEMS

  # Statements naming methods of their own class body that the strip rewrites
  # (strip_defs_from_source); their arguments are not calls.
  LIST_MIDS = UNREACHABLE_LIST_MIDS
  ATTR_MIDS = %i[attr attr_reader attr_writer attr_accessor].freeze
  # Calls whose first argument is a method name.
  BY_NAME_MIDS = %i[send __send__ public_send respond_to? method public_method instance_method
                    singleton_method define_method define_singleton_method alias_method
                    remove_method undef_method method_defined? public_method_defined?
                    private_method_defined? protected_method_defined? instance_methods].freeze

  # Names the VM or mruby core call without a call site in Ruby source.
  # Operators are added separately (any name that is not an identifier).
  IMPLICIT = %w[
    initialize initialize_copy initialize_dup initialize_clone allocate new
    to_s inspect to_str to_sym to_proc to_a to_ary to_h to_hash to_i to_int to_f to_r to_c
    hash eql? equal? coerce each call succ size length
    method_missing respond_to? respond_to_missing? const_missing
    inherited included extended prepended method_added singleton_method_added method_removed
    append_features extend_object prepend_features
    marshal_dump marshal_load _dump _load
    deconstruct deconstruct_keys exception message backtrace full_message
    dup clone freeze frozen?
  ].freeze

  # Each world site whose dispatched name is not a literal at the site, with
  # why every name it can dispatch is still a literal in the program (and so
  # counted). A new site fails the analysis until it is reviewed here; see ADR
  # 0218 and the closed-world lint that keeps them rare.
  REVIEWED = {
    ['mruby-lcf/mrblib/lcf.rb', 'obj.respond_to?(name)'] =>
      'LCF.field? names: schema field Symbols (schema.rb literals, or the blob strings on wio)',
    ['mruby-rgss/mrblib/error_report.rb', 'def method_missing(name, *args, &block)'] =>
      'Tee forwards call-site names to its IO',
    ['mruby-rgss/mrblib/error_report.rb', '@io.__send__(name, *args, &block)'] =>
      'Tee forwards call-site names to its IO',
    ['mruby-rgss/mrblib/error_report.rb', 'def respond_to_missing?(name, include_private = false)'] =>
      'Tee answers for its IO',
    ['mruby-rgss/mrblib/error_report.rb', '@io.respond_to?(name, include_private)'] =>
      'Tee answers for its IO',
    ['mruby-rpg2k/mrblib/game.rb', 'b.respond_to?(mod_field)'] =>
      'modified_stat callers pass :atk_mod/:def_mod/:spi_mod/:agi_mod literals',
    ['mruby-rpg2k/mrblib/game.rb', 'b.send(mod_field)'] =>
      'modified_stat callers pass :atk_mod/:def_mod/:spi_mod/:agi_mod literals',
    ['mruby-rpg2k/mrblib/scene/equip_menu.rb', '@state.party.send(effective_method, a)'] =>
      'STAT_DEFS literal Symbols',
    ['mruby-rpg2k/mrblib/scene/equip_menu.rb', 'a.send(accessor)'] =>
      'STAT_DEFS literal Symbols',
    ['mruby-lcf/schema_blob.rb', 'r.bytes(r.u8).to_sym'] =>
      'names from the BLOB literal, counted as a binary string',
    # game/battle.rb is not in the wio build; these matter for the desktop
    # test override (RPGMAKER_WIO_UNREACHABLE_HOST).
    ['mruby-rpg2k/mrblib/game/battle.rb', 'b.respond_to?(name)'] => 'flag_of callers pass predicate literals',
    ['mruby-rpg2k/mrblib/game/battle.rb', 'b.send(name)'] => 'flag_of callers pass predicate literals',
    ['mruby-rpg2k/mrblib/game/battle.rb', 'target.respond_to?(key)'] => 'STAT_MOD_FIELD literal keys',
    ['mruby-rpg2k/mrblib/game/battle.rb', 'target.send(key)'] => 'STAT_MOD_FIELD literal keys',
    ['mruby-rpg2k/mrblib/game/battle.rb', 'target.send(field)'] => 'STAT_MOD_FIELD literal values',
    ['mruby-rpg2k/mrblib/game/battle.rb', 'target.respond_to?(field)'] => 'a literal %i[atk_mod ...] list'
  }.freeze

  C_STRING = /"((?:[^"\\\n]|\\.)*)"/
  # An identifier not spelling an @ivar, @@cvar or $gvar (never a method name).
  NAME_IN_STRING = /(?<![@$A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*[?!=]?/n
  # Bytes that make a string a binary blob (length-prefixed names can run into
  # each other), matched by substring instead of by token.
  BINARY = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/n

  Unit = Struct.new(:name, :refs, :patterns, :blobs, :sites, :origin)
  Site = Struct.new(:file, :line, :text, :kind)

  def self.operator?(name)
    !name.match?(/\A[A-Za-z_]/)
  end

  # Adds what a string literal can name to `unit`.
  def self.add_string(unit, str)
    s = str.b
    if s.match?(BINARY)
      unit.blobs << s
    else
      s.scan(NAME_IN_STRING) do |t|
        unit.refs << t
        unit.refs << t[0..-2] if t.end_with?('?', '!', '=')
      end
    end
  end

  # Collects one file's units: the code outside any `def` (always run once
  # the file loads) and one unit per `def`.
  class Collector < Prism::Visitor
    attr_reader :units, :lists

    def initialize(rel, world)
      super()
      @rel = rel
      @world = world
      @top = Unit.new(nil, Set.new, [], [], [], "#{rel} (outside defs)")
      @units = [@top]
      @unit = @top
      @owners = []
      @lists = [] # [owner, name] from LIST_MIDS statements, world files only
    end

    def visit_class_node(node)
      visit(node.constant_path)
      visit(node.superclass) if node.superclass
      in_owner(const_name(node.constant_path)) { visit(node.body) if node.body }
    end

    def visit_module_node(node)
      visit(node.constant_path)
      in_owner(const_name(node.constant_path)) { visit(node.body) if node.body }
    end

    def visit_singleton_class_node(node)
      visit(node.expression)
      owner = node.expression.is_a?(Prism::SelfNode) && !@owners.empty? ? "#{@owners.join('::')}.singleton" : nil
      saved = @owners
      @owners = owner ? [owner] : [:opaque]
      visit(node.body) if node.body
      @owners = saved
    end

    def visit_def_node(node)
      visit(node.receiver) if node.receiver
      saved = @unit
      @unit = Unit.new(node.name.to_s, Set.new, [], [], [], "#{@rel}:#{node.location.start_line}")
      @units << @unit
      if @world && %i[method_missing respond_to_missing?].include?(node.name)
        site(node, :hook)
      end
      visit(node.parameters) if node.parameters
      visit(node.body) if node.body
      @unit = saved
    end

    def visit_call_node(node)
      name = node.name
      ref(name.to_s)
      args = node.arguments&.arguments || []
      literal_args = !args.empty? && args.all? { |a| a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }
      bare = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      if bare && ATTR_MIDS.include?(name) && literal_args
        # Defines accessors; calls nothing.
        visit(node.block) if node.block
        return
      end
      if bare && LIST_MIDS.include?(name) && literal_args && @world && @unit.equal?(@top) &&
         @owners.size.positive? && !@owners.include?(:opaque)
        owner = @owners.join('::')
        args.each { |a| @lists << [owner, literal_value(a)] }
        return
      end
      if @world
        first = args.first
        dynamic_name = first && !first.is_a?(Prism::SymbolNode) && !first.is_a?(Prism::StringNode) &&
                       !covered_by_pattern?(first)
        site(node, :by_name) if BY_NAME_MIDS.include?(name) && dynamic_name
        site(node, :to_sym) if %i[to_sym intern].include?(name) && !node.receiver.is_a?(Prism::StringNode)
      end
      super
    end

    def visit_call_operator_write_node(node)
      ref(node.read_name.to_s)
      ref(node.write_name.to_s)
      super
    end

    def visit_call_and_write_node(node)
      ref(node.read_name.to_s)
      ref(node.write_name.to_s)
      super
    end

    def visit_call_or_write_node(node)
      ref(node.read_name.to_s)
      ref(node.write_name.to_s)
      super
    end

    def visit_call_target_node(node)
      ref(node.name.to_s)
      super
    end

    def visit_for_node(node)
      ref('each')
      super
    end

    def visit_symbol_node(node)
      @unit.refs << node.unescaped.to_s
      super
    end

    def visit_string_node(node)
      WioUnreachable.add_string(@unit, node.unescaped)
      super
    end

    def visit_x_string_node(node)
      ref('`')
      WioUnreachable.add_string(@unit, node.unescaped)
      super
    end

    def visit_interpolated_symbol_node(node)
      pattern(node.parts, allow_empty: true)
      super
    end

    def visit_interpolated_string_node(node)
      pattern(node.parts, allow_empty: false)
      super
    end

    private

    def ref(name)
      @unit.refs << name
    end

    def in_owner(name)
      @owners.push(name || :opaque)
      yield
    ensure
      @owners.pop
    end

    # Same spelling as strip_wio_bc2cpp_stubs.rb's const_path_of.
    def const_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.slice.delete_prefix('::')
      end
    end

    def literal_value(node)
      node.is_a?(Prism::SymbolNode) ? node.unescaped.to_s : node.unescaped
    end

    # Whether `pattern` already keeps every name this interpolation can spell.
    def covered_by_pattern?(node)
      node.is_a?(Prism::InterpolatedSymbolNode) ||
        (node.is_a?(Prism::InterpolatedStringNode) && node.parts.any?(Prism::StringNode))
    end

    # An interpolated name can be any def name matching its static parts.
    def pattern(parts, allow_empty:)
      static = parts.select { |p| p.is_a?(Prism::StringNode) }
      return if static.empty? && !allow_empty

      src = parts.map { |p| p.is_a?(Prism::StringNode) ? Regexp.escape(p.unescaped.b) : '.*' }.join
      @unit.patterns << Regexp.new("\\A#{src}\\z".b,Regexp::MULTILINE | Regexp::NOENCODING)
    end

    def site(node, kind)
      @unit.sites << Site.new(@rel, node.location.start_line, node.slice.lines.first.strip, kind)
    end
  end

  Result = Struct.new(:dead, :live, :candidates, :unreviewed, keyword_init: true)

  # `world`: {gem => [[path, rel], ...]}; `ruby`/`native`: other sources.
  def self.analyze(world:, ruby:, native:)
    units = []
    lists = []
    candidates = []
    world.each do |gem, files|
      files.each do |path, rel|
        src = File.read(path, encoding: 'UTF-8')
        c = Collector.new("#{gem}/#{rel}", true)
        parse = Prism.parse(src)
        raise "#{path}: #{parse.errors.first.message}" unless parse.errors.empty?

        parse.value.accept(c)
        units.concat(c.units)
        lists.concat(c.lists)
        defs = []
        collect_defs(RubyVM::AbstractSyntaxTree.parse(src), [], defs)
        defs.each do |d|
          candidates << { gem: gem, rel: rel, owner: d[:owner], name: d[:name],
                          first: d[:node].first_lineno, last: d[:node].last_lineno }
        end
      end
    end
    ruby.each do |path|
      c = Collector.new(path, false)
      Prism.parse(File.read(path, encoding: 'UTF-8')).value.accept(c)
      units.concat(c.units)
    end

    seed = Unit.new(nil, Set.new(IMPLICIT), [], [], [], "hooks, native code and kept list statements")
    scan_native(seed, native)
    # A list statement naming a method its owner does not `def` here (an attr,
    # an inherited or native method) cannot be rewritten: it keeps the name.
    defined = candidates.to_set { |c| [c[:owner], c[:name]] }
    lists.each { |owner, name| seed.refs << name unless defined.include?([owner, name]) }
    units << seed

    live = propagate(units)
    dead = candidates.reject { |c| live.include?(c[:name]) || operator?(c[:name]) }
    unreviewed = units.select { |u| u.name.nil? || live.include?(u.name) }.flat_map(&:sites).reject do |s|
      REVIEWED.key?([s.file, s.text])
    end
    Result.new(dead: dead, live: live, candidates: candidates, unreviewed: unreviewed.uniq)
  end

  # The worklist: a unit's references count once its name is live. Returns
  # {live name => origin of the first unit that referenced it}.
  def self.propagate(units)
    def_names = units.filter_map(&:name).to_set
    by_name = units.group_by(&:name)
    live = {}
    queue = []
    run = lambda do |u|
      mark = lambda do |n|
        next if live.key?(n)

        live[n] = u.origin
        queue << n
      end
      u.refs.each(&mark)
      u.patterns.each { |re| def_names.each { |n| mark.call(n) if n.b.match?(re) } }
      u.blobs.each { |b| def_names.each { |n| mark.call(n) if b.include?(n.b) } }
    end
    by_name[nil].each(&run)
    until queue.empty?
      n = queue.shift
      by_name.fetch(n, []).each(&run)
    end
    live
  end

  # A native method definition's name argument: it defines, never dispatches.
  NATIVE_DEFINE = /\bmrb_define_(?:method|class_method|module_function|singleton_method)(?:_id)?\s*\(/
  NATIVE_ROM_ENTRY = /\bMRB_MT_ENTRY\s*\(\s*\w+\s*,\s*(#{MRB_SYM_TOKEN_RE})/o

  # Every name native code can dispatch: each string literal and MRB_SYM-family
  # token, except an occurrence that is only a method definition's name.
  def self.scan_native(unit, paths)
    paths.each do |path|
      text = File.binread(path).gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
        tok.start_with?('/') ? ' ' : tok
      end
      definitions = Hash.new(0)
      text.scan(NATIVE_DEFINE) do
        name = bc2cpp_c_call_args(Regexp.last_match.post_match)[2].to_s.strip
        definitions[name] += 1
      end
      text.scan(NATIVE_ROM_ENTRY) { |(tok)| definitions[tok] += 1 }
      literals = text.scan(C_STRING).map { |(s)| %("#{s}") }.tally
      literals.each do |lit, count|
        next if count <= definitions[lit]

        s = lit[1..-2]
        add_string(unit, unescape_c_string(s))
        # Escapes left as separators too, so "\rname" still yields `name`.
        add_string(unit, s.gsub(/\\(?:x\h{1,2}|[0-7]{1,3}|.)/, ' '))
      end
      text.scan(/#{MRB_SYM_TOKEN_RE}/o).map { |m, n| ["MRB_#{m}(#{n})", resolve_mrb_sym_token(m, n)] }.tally
          .each { |(tok, name), count| unit.refs << name if count > definitions[tok] }
    end
    unit.refs.merge(extract_native_call_names(paths))
  end

  # -- the wio world from checked-in sources (no rake) -------------------------

  # mrbgem.rake's evaluation with `build.name == 'wio'`: every call other than
  # `spec.rbfiles` is absorbed, so the file list comes out as rake sees it
  # before the wio_strip_* rewrites.
  class SpecProbe
    class Sink < BasicObject
      def method_missing(*) = self
      def respond_to_missing?(*) = true
    end

    Build = Struct.new(:name)
    attr_accessor :rbfiles
    attr_reader :dir, :build_dir

    def initialize(dir, build_dir)
      @dir = dir
      @build_dir = build_dir
      @rbfiles = Dir.glob("#{dir}/mrblib/**/*.rb").sort
    end

    def build = Build.new('wio')
    def method_missing(*) = Sink.new
    def respond_to_missing?(*) = true
  end

  def self.probe_rbfiles(gem_dir, build_dir)
    probe = SpecProbe.new(gem_dir, build_dir)
    spec_class = Class.new { define_singleton_method(:new) { |_name, &blk| probe.instance_exec(probe, &blk) } }
    mruby = Module.new
    mruby.const_set(:Gem, Module.new)
    mruby::Gem.const_set(:Specification, spec_class)
    sandbox = Module.new
    sandbox.const_set(:MRuby, mruby)
    # Evaluated with MRuby resolving to the stub above.
    sandbox.module_eval(File.read("#{gem_dir}/mrbgem.rake", encoding: 'UTF-8'), "#{gem_dir}/mrbgem.rake")
    probe.rbfiles
  end

  # The generated rbfiles a gem's wio rbfiles can name, keyed by basename.
  GENERATED = {
    'schema_blob.rb' => ->(out) { ['mruby-lcf/gen_schema_blob.rb', 'mruby-lcf/mrblib/schema.rb', out] }
  }.freeze

  # The wio chain of mrblib rewrites before this strip, in build_config order.
  def self.chain_for(gem)
    scripts = []
    scripts << File.join(ROOT, 'scripts/strip_wio_inline_helpers.rb') if gem == 'mruby-rpg2k'
    scripts << File.join(ROOT, 'scripts/strip_wio_debug_output.rb')
  end

  # {gem => [[path, rel], ...]} of the rewritten wio rbfiles, in `tmp`.
  def self.checked_in_world(tmp, chain: method(:chain_for))
    WORLD_GEMS.to_h do |gem|
      gem_dir = File.join(ROOT, gem)
      build_dir = File.join(tmp, 'build', gem)
      files = probe_rbfiles(gem_dir, build_dir).map do |src|
        unless File.exist?(src)
          gen = GENERATED.fetch(File.basename(src)) { raise "#{gem}: no generator for #{src}" }
          FileUtils.mkdir_p(File.dirname(src))
          script, *args = gen.call(src)
          _o, err, st = Open3.capture3(RbConfig.ruby, File.join(ROOT, script), *args.map { |a| a == src ? a : File.join(ROOT, a) })
          raise "#{script}: #{err}" unless st.success?
        end
        rel = src.start_with?("#{gem_dir}/") ? src.delete_prefix("#{gem_dir}/") : File.basename(src)
        input = src
        # A step is a script, or [script, the one gem-relative file it rewrites].
        chain.call(gem).each_with_index do |(script, only), i|
          next if only && only != rel

          out = File.join(tmp, "chain#{i}", gem, rel)
          FileUtils.mkdir_p(File.dirname(out))
          _o, err, st = Open3.capture3(RbConfig.ruby, script, input, out)
          raise "#{rel}: #{File.basename(script)}: #{err}" unless st.success?

          input = out
        end
        [input, rel]
      end
      [gem, files]
    end
  end

  # The wio build's gem list (its mrbgems/active_gems.txt), for the
  # checked-in mode only: the build step reads the real list and fails when
  # this one no longer matches it.
  WIO_GEMS = %w[
    hal-wio-io mruby-array-ext mruby-bigint mruby-enum-ext mruby-enumerator mruby-exit mruby-fiber
    mruby-hash-ext mruby-io mruby-lcf mruby-marshal mruby-math-wio mruby-metaprog mruby-numeric-ext
    mruby-pack mruby-range-ext mruby-rgss mruby-rpg2k mruby-sprintf mruby-string-ext mruby-stringio
    mruby-struct
  ].freeze

  # {gem => dir}. A gem missing from this checkout (CI's ruby-checks job has no
  # submodules) is left out and named in `missing`: fewer outside sources can
  # only make more names look unreachable, never fewer.
  def self.checked_in_gem_dirs(missing: nil)
    WIO_GEMS.each_with_object({}) do |g, h|
      dir = [g, "3rd/mruby/mrbgems/#{g}", "3rd/#{g}", "app/wio/#{g}"].map { |d| File.join(ROOT, d) }
                                                                     .find { |d| File.exist?("#{d}/mrbgem.rake") }
      if dir
        h[g] = dir
      elsif missing
        missing << g
      else
        raise "WIO_GEMS: no mrbgem.rake for #{g} (is 3rd/ checked out?)"
      end
    end
  end

  # [ruby, native]: the sources sharing the closed world's VM (ADR 0210's
  # bc2cpp_closed_world_outside_srcs), whose host sources in app/wio/src
  # carry the entry points (RPG2k.new, main_loop, current_scene_name).
  def self.outside_srcs(gem_dirs)
    native, ruby = bc2cpp_closed_world_outside_srcs('wio', gem_dirs, ROOT)
    [ruby, native]
  end

  # -- bytecode cost (--mrbc) ----------------------------------------------------

  IREP_STRUCT = 44 # sizeof(mrb_irep) on the 32-bit target
  IrepNode = Struct.new(:ilen, :syms, :reps, :pools, :strbytes, :lines, :children, :defs)

  # {[first_line, name] => bytes}: each method's irep tree (body and blocks),
  # as cdump lays it out, plus its reps slot in the parent.
  def self.method_costs(mrbc, path)
    out, err, st = Open3.capture3(mrbc, '-v', '-o', File::NULL, path)
    raise "mrbc #{path}: #{err}" unless st.success?

    ireps = []
    out.b.each_line do |l|
      if (m = l.match(/^irep 0x\h+ nregs=\d+ nlocals=\d+ pools=(\d+) syms=(\d+) reps=(\d+)(?: ilen=(\d+))?/n))
        ireps << IrepNode.new(m[4].to_i, m[2].to_i, m[3].to_i, m[1].to_i, 0, [], [], {})
      elsif ireps.last && (m = l.match(/^\s*(\d+) \d{3,} (\w+)\s+(.*)$/n))
        cur = ireps.last
        cur.lines << m[1].to_i
        op, args = m[2], m[3]
        idx = args[/I\[(\d+)\]/n, 1]
        if %w[TDEF SDEF].include?(op) && idx
          cur.defs[idx.to_i] = args[/:(\S+)/n, 1]
        elsif op == 'METHOD' && idx
          cur.defs[:pending] = idx.to_i
        elsif op == 'DEF' && cur.defs.key?(:pending)
          cur.defs[cur.defs.delete(:pending)] = args[/:(\S+)/n, 1]
        end
        cur.strbytes += Regexp.last_match(1).bytesize + 1 if op.match?(/STRING/) && args =~ /; (.*)$/n
      end
    end
    pos = 0
    build = lambda do
      ir = ireps[pos]
      pos += 1
      ir.reps.times { ir.children << build.call }
      ir
    end
    root = build.call
    cost = ->(ir) { ir.ilen + 4 * ir.syms + 4 * ir.reps + IREP_STRUCT + 8 * ir.pools + ir.strbytes + ir.children.sum(&cost) }
    first_line = ->(ir) { ([ir.lines.min] + ir.children.map(&first_line)).compact.min }
    costs = {}
    walk = lambda do |ir|
      ir.children.each_with_index do |ch, i|
        name = ir.defs[i]
        costs[[first_line.call(ch), name.to_s.force_encoding('UTF-8')]] = cost.call(ch) + 4 if name
        walk.call(ch)
      end
    end
    walk.call(root)
    costs
  end
end


module WioUnreachable
  # {owner => Set[name]}, the shape strip_wio_unreachable_methods.rb loads.
  def self.by_owner(dead)
    dead.each_with_object(Hash.new { |h, k| h[k] = Set.new }) { |d, h| h[d[:owner]] << d[:name] }
  end

  def self.tsv_rows(dead)
    dead.map { |d| [d[:owner], d[:name], d[:gem], d[:rel], d[:first]].join("\t") }.sort.uniq
  end

  # Raises (with every reason) unless the analysis may be trusted.
  def self.check!(res)
    return if res.unreviewed.empty?

    lines = res.unreviewed.map { |s| "  #{s.file}:#{s.line}: unreviewed #{s.kind} site: #{s.text}" }
    raise "a reachable site dispatches a computed name; review it in WioUnreachable::REVIEWED " \
          "or make the name a literal:\n#{lines.join("\n")}"
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  args = ARGV.dup
  until args.empty?
    case (a = args.shift)
    when '--manifest' then opts[:manifest] = args.shift
    when '--out' then opts[:out] = args.shift
    when '--mrbc' then opts[:mrbc] = args.shift
    when '--why' then (opts[:why] ||= []) << args.shift
    when '--write-stripped' then opts[:write] = args.shift
    else abort "unknown argument #{a}"
    end
  end

  if opts[:manifest]
    m = JSON.parse(File.read(opts[:manifest]))
    if m['build'] == 'wio' && m['gems'].sort != WioUnreachable::WIO_GEMS.sort
      abort "wio_unreachable_methods: WIO_GEMS is stale; the wio build's gems are now #{m['gems'].sort.join(' ')}"
    end
    res = WioUnreachable.analyze(world: m['world'], ruby: m['ruby'], native: m['native'])
    begin
      WioUnreachable.check!(res)
    rescue RuntimeError => e
      abort "wio_unreachable_methods: #{e.message}"
    end
    File.write(opts[:out], WioUnreachable.tsv_rows(res.dead).map { |r| "#{r}\n" }.join)
    warn "wio_unreachable_methods: #{res.dead.size} unreachable defs of #{res.candidates.size}"
    exit
  end

  Dir.mktmpdir do |tmp|
    world = WioUnreachable.checked_in_world(tmp)
    ruby, native = WioUnreachable.outside_srcs(WioUnreachable.checked_in_gem_dirs)
    res = WioUnreachable.analyze(world: world, ruby: ruby, native: native)
    begin
      WioUnreachable.check!(res)
    rescue RuntimeError => e
      abort "wio_unreachable_methods: #{e.message}"
    end
    opts[:why]&.each { |n| puts "#{n}: #{res.live[n] ? "live via #{res.live[n]}" : 'unreachable'}" }
    if opts[:write]
      by_owner = WioUnreachable.by_owner(res.dead)
      world.each do |gem, files|
        files.each do |path, rel|
          out = File.join(opts[:write], gem, rel)
          FileUtils.mkdir_p(File.dirname(out))
          File.write(out, strip_defs_from_source(File.read(path, encoding: 'UTF-8'), by_owner, path,
                                                 list_names_by_owner: by_owner,
                                                 visibility_mids: UNREACHABLE_LIST_MIDS))
        end
      end
    end
    costs = {}
    world.each { |gem, files| files.each { |path, rel| costs[[gem, rel]] = WioUnreachable.method_costs(opts[:mrbc], path) } } if opts[:mrbc]
    total = 0
    res.dead.sort_by { |d| [d[:gem], d[:rel], d[:first]] }.each do |d|
      bytes = costs[[d[:gem], d[:rel]]]&.find { |(line, name), _| name == d[:name] && line.between?(d[:first], d[:last]) }&.last
      total += bytes.to_i
      puts format('%-6s %-28s %-46s %s', d[:gem].delete_prefix('mruby-'), "#{d[:rel]}:#{d[:first]}",
                  "#{d[:owner]}##{d[:name]}", bytes || '')
    end
    puts "#{res.dead.size} unreachable defs (#{res.dead.map { |d| d[:name] }.uniq.size} names) " \
         "of #{res.candidates.size}#{opts[:mrbc] ? ", #{total} bytes of bytecode (model)" : ''}"
  end
end
