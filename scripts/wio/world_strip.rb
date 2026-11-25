# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'prism'
require 'set'
require 'rbconfig'

# WIO_WORLD_STRIP: the wio-only mrblib rewrites, applied to the closed world bc2cpp compiles for wio. The VM-free build
# loads no mrblib, so a rewrite reaches the firmware only through these sources. build_config.rb's wio_strip_world
# wires it in; scripts/wio/strip_scripts_check.rb runs every pass over every engine file.
#
# WIO_WORLD_STRIP=0 compiles the world as it is; a comma list (inline,debug) names the passes to run instead of DEFAULT.
module WioWorldStrip
  ROOT = File.expand_path('../..', __dir__)
  KILL_ENV = 'WIO_WORLD_STRIP'
  # name => [script, gems it rewrites, the one repo-relative file it applies to (nil: every file of those gems)], in
  # chain order: strip_clock.rb matches the form strip_inline_helpers.rb leaves, so clock needs inline.
  PASSES = {
    'probes' => ['strip_rgss_probes.rb', %w[mruby-rgss], 'mruby-rgss/mrblib/lib.rb'],
    'inline' => ['strip_inline_helpers.rb', %w[mruby-rpg2k], nil],
    'clock' => ['strip_clock.rb', %w[mruby-rpg2k mruby-lcf mruby-rgss], nil],
    'debug' => ['strip_debug_output.rb', %w[mruby-rpg2k mruby-lcf mruby-rgss], nil]
  }.freeze
  # What a wio build runs by default. Not the others: probes and clock save under 1 KB each, and grow internal flash
  # (probes) or drop the no-clock save log line (clock), and debug deletes the [RPG2k]/[RGSS] logs of recovered errors.
  DEFAULT = %w[inline].freeze

  module_function

  def passes(env = ENV)
    value = env[KILL_ENV].to_s
    return DEFAULT if value.empty? || value == '1'
    return [] if value == '0'

    names = value.split(',').map(&:strip)
    unknown = names - PASSES.keys
    raise "#{KILL_ENV}=#{value}: unknown pass #{unknown.join(', ')} (#{PASSES.keys.join(', ')}, 0 or 1)" unless unknown.empty?
    raise "#{KILL_ENV}=#{value}: clock needs inline" if names.include?('clock') && !names.include?('inline')

    PASSES.keys & names
  end

  def scripts
    PASSES.values.map { |script, *| File.join(__dir__, script) }
  end

  # The scripts that rewrite `rel` (repo-relative), in chain order.
  def steps(rel, names)
    names.filter_map do |name|
      script, gems, only = PASSES.fetch(name)
      next unless gems.any? { |gem| rel.start_with?("#{gem}/") }
      next if only && rel != only

      File.join(__dir__, script)
    end
  end

  # `src` through `steps`, each output the next input. A script raises, and so stops the build, when its pattern no
  # longer matches the source.
  def rewrite(src, rel, steps, tmp_dir)
    input = src
    steps.each_with_index do |script, i|
      out = File.join(tmp_dir, i.to_s, rel)
      FileUtils.mkdir_p(File.dirname(out))
      _o, err, status = Open3.capture3(RbConfig.ruby, script, input, out)
      raise "#{File.basename(script)} failed on #{rel}:\n#{err}" unless status.success?

      input = out
    end
    File.read(input, encoding: 'UTF-8')
  end

  # `srcs` with each engine file a pass changes replaced by its copy under `out_dir`, at the same repo-relative path so
  # a path-suffix match on it still holds. A file no pass changes stays the original.
  def map(srcs, out_dir, names)
    return srcs if names.empty?

    srcs.map do |src|
      next src unless src.start_with?("#{ROOT}/")

      rel = src.delete_prefix("#{ROOT}/")
      steps = steps(rel, names)
      next src if steps.empty?

      text = rewrite(src, rel, steps, File.join(out_dir, '.steps'))
      next src if text == File.read(src, encoding: 'UTF-8')

      write_if_changed(File.join(out_dir, rel), text)
    end
  end

  # map, plus the world's signatures without the methods the passes deleted at out_dir/sig (SIG_FILTER).
  def world(srcs, out_dir, names)
    return srcs if names.empty?

    mapped = map(srcs, out_dir, names)
    filter_sig(File.join(ROOT, 'sig'), sig_dir(out_dir), defs(srcs) - defs(mapped))
    mapped
  end

  def sig_dir(out_dir)
    File.join(out_dir, 'sig')
  end

  # BC2CPP_SIG_DIRS (rbs_signatures.rb) with the world's sig/ swapped for the filtered copy; `default` is its list
  # when unset.
  def sig_dirs(out_dir, current, default)
    dirs = current ? current.split(File::PATH_SEPARATOR) : default
    dirs.map { |d| File.expand_path(d) == File.join(ROOT, 'sig') ? sig_dir(out_dir) : d }.join(File::PATH_SEPARATOR)
  end

  def write_if_changed(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text) unless File.exist?(path) && File.read(path, encoding: 'UTF-8') == text
    path
  end

  # [owner, singleton?, name] of every def in `paths`.
  def defs(paths)
    found = Set.new
    walk = lambda do |node, owner, singleton|
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::ClassNode, Prism::ModuleNode
        inner = [owner, node.constant_path.slice.delete_prefix('::')].compact.join('::')
        return walk.call(node.body, inner, false)
      when Prism::SingletonClassNode
        return walk.call(node.body, owner, true)
      when Prism::DefNode
        found << [owner || 'Object', singleton || node.receiver.is_a?(Prism::SelfNode), node.name.to_s]
      end
      node.compact_child_nodes.each { |child| walk.call(child, owner, singleton) }
    end
    paths.each { |path| walk.call(Prism.parse_file(path).value, nil, false) }
    found
  end

  # SIG_FILTER: a signature of a method a pass deleted names no method of the program, which bc2cpp refuses (TC1003).
  # Copies the world's sig/ to `out_dir` without the members of `deleted` ([owner, singleton?, name]), with their
  # annotations and comment, and returns the copy.
  def filter_sig(sig_dir, out_dir, deleted)
    require 'rbs'
    Dir[File.join(sig_dir, '**/*.rbs')].each do |path|
      text = File.read(path, encoding: 'UTF-8')
      drop = []
      _, _, decls = RBS::Parser.parse_signature(RBS::Buffer.new(name: path, content: text))
      sig_members(decls, nil) do |owner, member|
        singleton = member.kind == :singleton
        next unless deleted.include?([owner, singleton, member.name.to_s])

        starts = [member.location.start_line] + member.annotations.map { |a| a.location.start_line }
        starts << member.comment.location.start_line if member.comment&.location
        drop.concat((starts.min..member.location.end_line).to_a)
      end
      lines = text.lines
      kept = lines.each_with_index.reject { |_, i| drop.include?(i + 1) }.map(&:first).join
      write_if_changed(File.join(out_dir, path.delete_prefix("#{sig_dir}/")), kept)
    end
    out_dir
  end

  def sig_members(decls, outer, &block)
    decls.each do |decl|
      next unless decl.respond_to?(:members)

      name = decl.name.to_s.delete_prefix('::')
      owner = outer ? "#{outer}::#{name}" : name
      decl.members.each do |member|
        if member.is_a?(RBS::AST::Members::MethodDefinition)
          yield owner, member
        elsif member.respond_to?(:members)
          sig_members([member], owner, &block)
        end
      end
    end
  end
end
