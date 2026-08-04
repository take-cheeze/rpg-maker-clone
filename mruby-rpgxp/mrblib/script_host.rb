# RGSS script host — the "run the bundled scripts" path.
#
# An RPG Maker XP project ships its whole engine (title, map, event interpreter,
# menus, battle, …) as ~90 Ruby scripts inside Data/Scripts.rxdata. The native
# player, RGSS104E.dll, boots a game simply by evaluating those sections in order
# at the top level: the value types, Graphics/Input/Audio and the RPG data
# classes are provided by the DLL, and the final "Main" section runs the game
# loop (`$scene.main while $scene != nil`).
#
# This module is the mruby equivalent of that: given the project database it
# exposes the handful of Kernel built-ins the scripts expect the engine to
# supply (load_data / save_data / $RGSS_SCRIPTS), then evals each decompressed
# section against the top level using its editor name — so the game's own logic
# runs unmodified, rather than the reimplemented default flow in game.rb/scene.rb.
#
# It is the alternative to that reimplementation (see
# docs/adr/0017-rpgxp-rgss-script-host.md). Because the scripts drive their own
# blocking main loop and lean on the full RGSS class library, the host is an
# opt-in path for now (RPGXP::ScriptHost.enabled?), with the built-in flow as the
# default and the fallback. Requires mruby-eval for Kernel#eval.
class RPGXP
  # Defined with explicit `def self.` singleton methods (not a bare
  # `module_function`, which this mruby build does not apply to later defs) so
  # the host is callable as RPGXP::ScriptHost.<method>.
  module ScriptHost
    # Environment variable / constant that turns the script host on. Off by
    # default: the built-in flow is the verified path, and running the bundled
    # scripts needs both eval and a complete-enough RGSS class library.
    ENABLED_ENV = "RGSS_SCRIPT_HOST".freeze

    # Whether the runtime can eval Ruby source at all (mruby-eval present, or
    # CRuby). Kernel#eval is a public method under mruby-eval and a private one
    # under CRuby; the private check is itself CRuby-only (mruby's Module has no
    # private_method_defined?), so guard it with respond_to?.
    def self.available?
      return true if Kernel.method_defined?(:eval)
      Kernel.respond_to?(:private_method_defined?) &&
        Kernel.private_method_defined?(:eval)
    end

    # Whether to run the bundled scripts instead of the built-in flow. Requires
    # eval support and an explicit opt-in: the env var when the runtime exposes
    # ENV, otherwise the ENABLED constant (default false).
    def self.enabled?
      return false unless available?
      if defined?(ENV) && ENV.respond_to?(:[]) && !ENV[ENABLED_ENV].nil?
        flag = ENV[ENABLED_ENV]
        return !(flag.empty? || flag == "0" || flag == "false")
      end
      defined?(ENABLED) ? ENABLED : false
    end

    # Run the project's bundled scripts to completion. `db` answers #scripts
    # (an ordered array of [name, source]) and #read_object / #save_object for
    # the Kernel built-ins. Returns true when the scripts were run, false when
    # there was nothing to run (no scripts, or no eval) so the caller can fall
    # back to the built-in flow. Evaluating "Main" blocks here until the game's
    # own loop exits, exactly as RGSS does.
    def self.run(db)
      return false unless available?
      sections = db.scripts
      if sections.empty?
        $stderr.puts "[RGSS] script host: project ships no scripts; using built-in flow"
        return false
      end
      install_kernel(db)
      # RGSS exposes the loaded sections as $RGSS_SCRIPTS ([id, name, source]);
      # some scripts read it (e.g. to hot-reload). Mirror that shape.
      idx = -1
      $RGSS_SCRIPTS = sections.map { |name, source| [idx += 1, name, source] }
      top = defined?(TOPLEVEL_BINDING) ? TOPLEVEL_BINDING : nil
      sections.each do |name, source|
        # eval(str, binding, file, line): the section name becomes the "file" in
        # any backtrace, and top-level class/module definitions land on Object —
        # so `class Scene_Title` etc. define global constants, as under RGSS.
        eval(source, top, name, 1)
      end
      true
    end

    # The database the Kernel built-ins (Object#load_data / #save_data, defined
    # below) read and write through. Point it at the running project's database.
    def self.db
      @db
    end

    def self.install_kernel(db)
      @db = db
    end
  end
end

# RGSS scripts call load_data / save_data as global Kernel methods that the
# player (RGSS104E.dll) supplies. Define them on Object — the way lib.rb already
# reopens Object for the RGSS value-type names — routed through the script host's
# current database so a loose file and the encrypted archive both resolve. Plain
# method bodies (no runtime class_eval / define_method) so the build needs no
# metaprogramming helpers; they no-op safely until the host sets ScriptHost.db.
class Object
  def load_data(filename)
    RPGXP::ScriptHost.db.read_object(filename)
  end

  def save_data(obj, filename)
    RPGXP::ScriptHost.db.save_object(obj, filename)
  end
end
