# frozen_string_literal: true

# A Rake stand-in for mruby's own build, so that mruby's Rakefile, its lib/mruby/build.rb and tasks/*.rake plan the
# graph without rake, and ninja runs it. The planner loads the real Rakefile under this shim; nothing runs while planning
# except the actions of mruby's command runner (lib/mruby/build/command.rb), whose sh calls are recorded, not executed.
# Any other action (a gem's Ruby block, bc2cpp's codegen) becomes a `gemtask` edge: ninja runs that block for real, by
# planning the same Rakefile again and executing the one task.
#
#   ruby scripts/mruby-ninja-rake.rb generate MRUBY_SRC OUT   writes OUT/build.ninja (MRUBY_CONFIG selects the config)
#   ruby scripts/mruby-ninja-rake.rb gemtask MRUBY_SRC TASK  runs one planned task for real (ninja's gemtask edge)

require 'fileutils'
require 'shellwords'

module RakeShim
  # The environment a build config and its planning read; a gemtask run gets the same (see Emitter#emit).
  PLAN_ENV = %w[MRUBY_BUILD_DIR MRUBY_CONFIG MRUBY_TARGET MRUBY_CC MRUBY_LD RPGMAKER_BC2CPP NFCXX_ROOT CC CXX AR
                CFLAGS LDFLAGS].freeze

  Node = Struct.new(:name, :kind, :prereqs, :actions, :desc) do
    # Rake::Task's view of a node.
    def prerequisites = prereqs
    def sources = prereqs
    def source = prereqs.first

    def enhance(deps = [], &block)
      self.prereqs |= RakeShim.as_list(deps).map { |d| RakeShim.prereq_name(d) }
      actions << block if block
      self
    end

    def invoke(*) = nil
  end

  class << self
    attr_accessor :mode # :plan or :exec
    attr_reader :nodes, :namespace_stack

    def reset!
      @nodes = {}
      @namespace_stack = []
      @mode = :plan
      @plan_log = nil
    end

    def qualify(name)
      name = name.to_s
      return name if name.start_with?('/') || @namespace_stack.empty?

      (@namespace_stack + [name]).join(':')
    end

    # rule MATCHER => [SOURCE, DEPS] do |t| ... end: MATCHER is a Regexp or a suffix String; SOURCE and DEPS are Procs of
    # the target name (or plain strings), as Rake takes them.
    def add_rule(args, block)
      matcher, sources = args.first
      @rules ||= []
      @rules << [matcher, Array(sources), block]
    end

    # Rake's implicit rules: a missing file that a rule matches gets a node whose prerequisites are the rule's sources,
    # when the first source exists or can itself be planned. Returns the new node, or nil.
    def implicit_node(name)
      (@rules || []).each do |matcher, sources, block|
        next unless matcher.is_a?(Regexp) ? name.match?(matcher) : name.end_with?(matcher.to_s)

        prereqs = sources.flat_map { |s| s.is_a?(Proc) ? Array(s.call(name)) : [s] }.compact.flatten
        first = prereqs.first
        next unless first && (@nodes.key?(first) || File.exist?(first) || implicit_node(first))

        node = Node.new(name, :file, prereqs, [block], nil)
        @nodes[name] = node
        return node
      end
      nil
    end

    # Rake.application.options: mruby's _pp prints its command lines unless silent.
    def options = @options ||= Struct.new(:silent, :trace, :dryrun).new(true, false, false)
    # Every prerequisite with no node of its own may be an implicit rule's target: create those nodes, to a fixed point.
    def resolve_implicit_closure
      queue = @nodes.values.dup
      until queue.empty?
        node = queue.shift
        node.prereqs.each do |p|
          next if @nodes.key?(p)

          created = implicit_node(p)
          queue << created if created
        end
        # A file with no action and not on disk takes a matching rule's action (Rake's enhance_with_matching_rule).
        queue << node if node.kind == :file && node.actions.empty? && !File.exist?(absolute_name(node.name)) && apply_rule(node)
      end
    end

    # The rule that matches a node (see implicit_node), added to the node as its action and prerequisites.
    def apply_rule(node)
      (@rules || []).each do |matcher, sources, block|
        next unless matcher.is_a?(Regexp) ? node.name.match?(matcher) : node.name.end_with?(matcher.to_s)

        prereqs = sources.flat_map { |s| s.is_a?(Proc) ? Array(s.call(node.name)) : [s] }.compact.flatten
        next unless prereqs.first && (@nodes.key?(prereqs.first) || File.exist?(prereqs.first) || implicit_node(prereqs.first))

        node.prereqs |= prereqs
        node.actions << block
        return true
      end
      false
    end

    def absolute_name(name) = File.expand_path(name, @plan_root || Dir.pwd)

    def lookup(name) = @nodes[name]
    def enhance_with_matching_rule(name) = implicit_node(name)

    def node_for(name, kind)
      name = qualify(name)
      @nodes[name] ||= Node.new(name, kind, [], [], nil)
    end

    def declare(kind, args, block)
      if args.first.is_a?(Hash)
        deps = args.first.values.first
        name = args.first.keys.first
      else
        name = args.first
        deps = args[1..] || []
      end
      node = node_for(name, kind)
      node.kind = :file if kind == :file
      node.prereqs |= as_list(deps).map { |d| prereq_name(d) }
      node.actions << block if block
      node
    end

    # A prerequisite list: a name, a task object, or an array of either. A task object is not expanded into its fields.
    def as_list(deps)
      (deps.is_a?(Array) ? deps.flatten : [deps]).compact
    end

    # A prerequisite is a name, or a task object (presym.rake passes one).
    def prereq_name(dep)
      dep.is_a?(Node) ? dep.name : qualify(dep)
    end


    # Records a planned operation for the task whose action is running.
    def record(op)
      @plan_log << op if @plan_log
    end

    # Plans one node: runs each of its actions that the command runner owns, recording their operations.
    # Returns [ops, gemtask?]; gemtask? is true when an action is not the command runner's.
    def plan_actions(node)
      ops = []
      needs_gemtask = false
      node.actions.each do |blk|
        if [File.join(@plan_root.to_s, 'lib/mruby/build/command.rb'), __FILE__].include?(blk.source_location&.first)
          @plan_log = []
          blk.call(node)
          ops.concat(@plan_log)
          @plan_log = nil
        else
          needs_gemtask = true
        end
      end
      [ops, needs_gemtask]
    end

    def run_action_for_real(node)
      node.actions.each { |blk| blk.call(node) }
    end
  end

  # The DSL a Rakefile sees at top level (Rake::DSL).
  module DSL
    module_function

    def task(*args, &block) = RakeShim.declare(:task, args, block)
    def file(*args, &block) = RakeShim.declare(:file, args, block)

    def directory(dir, &block)
      RakeShim.declare(:file, [dir], nil)
      RakeShim.node_for(dir, :file).actions << ->(_t) { RakeShim.op(:mkdir, dir) }
      RakeShim.node_for(dir, :file).actions << block if block
      nil
    end

    def namespace(name)
      RakeShim.namespace_stack.push(name.to_s)
      yield
    ensure
      RakeShim.namespace_stack.pop
    end

    def desc(text) = text
    def rule(args = {}, &block) = RakeShim.add_rule(args, block)
    def multitask(*args, &block) = task(*args, &block)
    def verbose(*) = false

    def sh(*cmd, &_block)
      words = cmd.reject { |c| c.is_a?(Hash) }
      RakeShim.sh_command(words.join(' '), cmd.first.is_a?(Hash) ? cmd.first : {})
    end

    def mkdir_p(dir, **) = RakeShim.op(:mkdir, dir)
    def rm_rf(*paths, **) = paths.flatten.each { |p| RakeShim.op(:rm, p) }
    def rm_f(*paths, **) = rm_rf(*paths)
    def cp(src, dest, **) = RakeShim.op(:cp, src, dest)
    def touch(*paths, **) = paths.flatten.each { |p| RakeShim.op(:touch, p) }
    def ruby(*args) = RakeShim.sh_command(args.join(' '), {})
  end
end

# Rake's own names, as mruby's files use them.
module Rake
  DEFAULT = Object.new.freeze
  module DSL
    DEFAULT = ::Rake::DEFAULT
  end

  def self.verbose(value = nil) = value.nil? ? false : nil

  def self.application = RakeShim

  class Task
    def self.[](name)
      name = RakeShim.qualify(name)
      RakeShim.nodes[name] || RakeShim.implicit_node(name) ||
        (File.exist?(name) && RakeShim.node_for(name, :file)) || raise("no task #{name}")
    end
    def self.task_defined?(name) = RakeShim.nodes.key?(RakeShim.qualify(name))
  end
end

class << RakeShim
  # Recorded operations. In exec mode they run for real.
  def op(kind, *args)
    if @mode == :plan
      record([kind, *args])
    else
      case kind
      when :mkdir then FileUtils.mkdir_p(args[0])
      when :rm then FileUtils.rm_rf(args[0])
      when :cp then FileUtils.cp(args[0], args[1])
      when :touch then FileUtils.touch(args[0])
      end
    end
  end

  def sh_command(command, env)
    if @mode == :plan
      record([:sh, env, command])
    else
      system(env, command, exception: true)
    end
    nil
  end
end

Object.include(RakeShim::DSL)

# Loads mruby's Rakefile under the shim, the same way `rake` would (MRUBY_CONFIG selects the config).
def RakeShim.load_rakefile(mruby_src)
  reset!
  mruby_src = File.expand_path(mruby_src)
  $LOAD_PATH << File.join(mruby_src, 'lib')
  @plan_root = mruby_src
  Dir.chdir(mruby_src) { load File.join(mruby_src, 'Rakefile') }
end

module RakeShim
  # The ninja build file for every target's file tasks (and phony tasks) the Rakefile planned.
  class Emitter
    def initialize(mruby_src, out)
      @mruby_src = File.expand_path(mruby_src)
      @out = File.expand_path(out)
      @lines = []
      @stamps = {}
      @products = []
    end

    def emit
      resolve_implicit_prereqs
      @presym_dirs = RakeShim.nodes.keys.select { |n| n.end_with?('/presym') }.map { |n| File.dirname(absolute(n)) }
      @lines << "ninja_required_version = 1.7"
      @lines << "gen = #{Shellwords.escape(File.expand_path(__FILE__))}"
      @lines << "ruby = #{Shellwords.escape(RbConfig.ruby)}"
      @lines << "mruby_src = #{Shellwords.escape(@mruby_src)}"
      @lines << "rule sh"
      @lines << "  command = $cmd"
      @lines << "  description = $desc"
      # The planning environment (the build directory, the config) is the same in each gemtask run, so it is passed on.
      buildenv = PLAN_ENV.select { |k| ENV[k] }.map { |k| "#{k}=#{Shellwords.escape(ENV[k])}" }
      @lines << "buildenv = #{ninja_value(buildenv.join(' '))}"
      @lines << "rule gemtask"
      @lines << "  command = $buildenv $ruby $gen gemtask $mruby_src $taskname"
      @lines << "  description = TASK $taskname"
      RakeShim.nodes.each_value { |node| emit_node(node) }
      # `all` is rake's default: mruby's own :build task (the targets' products), when the Rakefile declares it.
      goal = RakeShim.nodes['build'] ? phony_name('build') : @products.uniq.join(' ')
      @lines << "build all: phony #{goal}" unless goal.empty?
      @lines << "default all"
      @lines.join("\n") + "\n"
    end

    private

    def resolve_implicit_prereqs = RakeShim.resolve_implicit_closure

    def emit_node(node)
      if node.actions.empty?
        if node.kind == :task
          name = phony_name(node.name)
          @lines << "build #{name}: phony #{node.prereqs.map { |p| phony_ref(p) }.join(' ')}"
          @products << name
          return
        end
        # A file with no action of its own, and not on disk, is made by its prerequisites (a task that writes it).
        return if File.exist?(absolute(node.name)) || node.prereqs.empty?

        target = ninja_path(absolute(node.name))
        @lines << "build #{target}: phony #{node.prereqs.map { |p| phony_ref(p) }.join(' ')}"
        @products << target
        return
      end

      ops, gemtask = RakeShim.plan_actions(node)
      deps = node.prereqs.map { |p| phony_ref(p) }
      order = order_only(node)
      if gemtask
        target = node.kind == :file ? ninja_path(absolute(node.name)) : stamp_for(node.name)
        outputs = [target, *presym_headers(node).map { |h| ninja_path(h) }]
        @lines << "build #{outputs.join(' ')}: gemtask #{deps.join(' ')}#{order}"
        @lines << "  taskname = #{Shellwords.escape(node.name)}"
      elsif ops.any?
        command = ops.map { |op| op_command(op) }.join(' && ')
        target = node.kind == :file ? ninja_path(absolute(node.name)) : stamp_for(node.name)
        @lines << "build #{target}: sh #{deps.join(' ')}#{order}"
        @lines << "  cmd = #{ninja_value(command)}"
        @lines << "  desc = #{ninja_value(node.name)}"
      else
        return
      end
      if node.kind == :task
        @lines << "build #{phony_name(node.name)}: phony #{target}"
        @products << phony_name(node.name)
      else
        @products << target
      end
    end

    def op_command(op)
      kind, *args = op
      case kind
      when :sh
        env, command = args
        prefix = env.map { |k, v| "#{k}=#{Shellwords.escape(v.to_s)}" }.join(' ')
        [prefix, command].reject(&:empty?).join(' ')
      when :mkdir then "mkdir -p #{Shellwords.escape(args[0])}"
      when :rm then "rm -rf #{Shellwords.escape(args[0])}"
      when :cp then "cp #{Shellwords.escape(args[0])} #{Shellwords.escape(args[1])}"
      when :touch then "touch #{Shellwords.escape(args[0])}"
      end
    end

    # A prerequisite of a task (a phony name) or of a file (its ninja path).
    def phony_ref(name)
      node = RakeShim.nodes[name]
      return ninja_path(absolute(name)) if node.nil? || node.kind == :file

      phony_name(name)
    end

    # The presym pass writes the headers (include/mruby/presym/{id,table}.h) as a side effect of its block, so its edge
    # declares them as outputs, and each object of its build directory waits for them (order-only: they are not inputs).
    def presym_headers(node)
      return [] unless node.kind == :file && absolute(node.name).end_with?('/presym')

      dir = File.dirname(absolute(node.name))
      %w[id table].map { |h| File.join(dir, 'include', 'mruby', 'presym', "#{h}.h") }
    end

    def order_only(node)
      return '' unless node.name.end_with?('.o')

      path = absolute(node.name)
      dir = @presym_dirs.select { |d| path.start_with?("#{d}/") }.max_by(&:length)
      return '' unless dir

      headers = %w[id table].map { |h| File.join(dir, 'include', 'mruby', 'presym', "#{h}.h") }
      " || #{headers.map { |h| ninja_path(h) }.join(' ')}"
    end

    # Injective: a character outside the safe set is written as its hex code, so no two task names share a name.
    def safe_name(name) = name.gsub(/[^A-Za-z0-9.-]/) { |c| format('%%%02x', c.ord) }

    def phony_name(name) = "task-#{safe_name(name)}"

    def stamp_for(name)
      @stamps[name] ||= File.join(@out, 'stamps', "#{safe_name(name)}.stamp")
    end

    def absolute(name) = File.expand_path(name, @mruby_src)

    def ninja_path(path) = path.gsub(/[ :$]/) { |c| "$#{c}" }

    def ninja_value(text) = text.to_s.gsub('$', '$$')
  end
end


# Rake's String#pathmap, for the patterns mruby's build files use.
class String
  # Rake's String#ext: replaces the extension with new_ext (empty removes it).
  def ext(new_ext = '')
    sub(/\.[^.\/]*\z/, new_ext)
  end

  def pathmap(pattern)
    pattern.gsub(/%[nXfxd]/) do |token|
      case token
      when '%n' then File.basename(self, File.extname(self))
      when '%X' then delete_suffix(File.extname(self))
      when '%f' then File.basename(self)
      when '%x' then File.extname(self)
      when '%d' then File.dirname(self)
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  cmd, *args = ARGV
  case cmd
  when 'generate'
    abort 'usage: mruby-ninja-rake.rb generate MRUBY_SRC OUT' unless args.size == 2
    RakeShim.load_rakefile(args[0])
    out = File.expand_path(args[1])
    FileUtils.mkdir_p(out)
    File.write(File.join(out, 'build.ninja'), RakeShim::Emitter.new(args[0], out).emit)
    warn "mruby-ninja-rake: #{RakeShim.nodes.size} tasks planned"
  when 'gemtask'
    abort 'usage: mruby-ninja-rake.rb gemtask MRUBY_SRC TASK' unless args.size == 2
    RakeShim.load_rakefile(args[0])
    RakeShim.resolve_implicit_closure
    RakeShim.mode = :exec
    node = RakeShim.nodes[args[1]] || RakeShim.implicit_node(args[1]) or abort "no task #{args[1]}"
    RakeShim.run_action_for_real(node)
  else
    abort 'usage: mruby-ninja-rake.rb generate MRUBY_SRC OUT | gemtask MRUBY_SRC TASK'
  end
end
