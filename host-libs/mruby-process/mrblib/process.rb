# Open3, Process and RbConfig over BC2CPPProcess (src/process.c). Commands run without a shell, as Open3 does with
# more than one argument. A child's environment changes are given as a Hash; a nil value unsets the name.
module Process
  CLOCK_MONOTONIC = 1 unless const_defined?(:CLOCK_MONOTONIC)

  # A child's exit status: success?, exitstatus and to_i, as Process::Status gives them.
  class Status
    attr_reader :exitstatus

    def initialize(code)
      @exitstatus = code
    end

    def to_i
      @exitstatus
    end

    def success?
      @exitstatus == 0
    end

    def ==(other)
      other.respond_to?(:to_i) && other.to_i == to_i
    end
  end

  def self.pid
    BC2CPPProcess.pid
  end

  def self.clock_gettime(_id = CLOCK_MONOTONIC, _unit = :float_second)
    BC2CPPProcess.monotonic
  end

  def self.wait2(*)
    raise NotImplementedError, 'Process.wait2: no child processes are tracked (Open3 waits for its own)'
  end
end

module Open3
  # Runs a command: [stdout, stderr, Process::Status]. args may start with an env Hash and end with an options Hash
  # (stdin_data:).
  def self.capture3(*args)
    env = args.first.is_a?(Hash) ? args.shift : {}
    opts = args.last.is_a?(Hash) ? args.pop : {}
    raise ArgumentError, 'capture3: no command' if args.empty?

    overrides = env.map { |k, v| [k.to_s, v.nil? ? nil : v.to_s] }
    out, err, code = BC2CPPProcess.run(args.map(&:to_s), overrides, opts[:stdin_data])
    [out, err, Process::Status.new(code)]
  end

  # Runs a command: [stdout, Process::Status].
  def self.capture2(*args)
    out, _err, status = capture3(*args)
    [out, status]
  end

  # Runs a command: [stdout and stderr together, Process::Status]. The two streams are joined, not interleaved as
  # they were written, which the tools do not rely on.
  def self.capture2e(*args)
    out, err, status = capture3(*args)
    [out + err, status]
  end
end

# The features the tools require by name and this gem provides. RbConfig is mruby-require's (BC2CPP_RUBY).
MRubyRequire.provide('open3') { defined?(Open3) ? true : false }

module Kernel
  # Kernel#system: runs a command (no shell), passing its output on, and returns whether it succeeded. exception: true
  # raises when it fails, as CRuby's does. A command that could not be run (exit 127 with no output) returns nil.
  def system(*args, **opts)
    env = args.first.is_a?(Hash) ? args.shift : {}
    raise ArgumentError, 'system: no command' if args.empty?

    out, err, status = Open3.capture3(env, *args)
    $stdout.write(out) unless out.empty?
    $stderr.write(err) unless err.empty?
    if status.exitstatus == 127 && out.empty? && err.empty?
      raise RuntimeError, "No such file or directory - #{args.first}" if opts[:exception]

      return nil
    end
    raise RuntimeError, "Command failed with exit #{status.exitstatus}: #{args.join(' ')}" if opts[:exception] && !status.success?

    status.success?
  end
end
