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
  module ScriptHost
    module_function

    # Environment variable / constant that turns the script host on. Off by
    # default: the built-in flow is the verified path, and running the bundled
    # scripts needs both eval and a complete-enough RGSS class library.
    ENABLED_ENV = "RGSS_SCRIPT_HOST".freeze

    # Whether the runtime can eval Ruby source at all (mruby-eval present, or
    # CRuby). Kernel#eval is public in mruby-eval and private in CRuby.
    def available?
      Kernel.method_defined?(:eval) || Kernel.private_method_defined?(:eval)
    end

    # Whether to run the bundled scripts instead of the built-in flow. Requires
    # eval support and an explicit opt-in: the env var when the runtime exposes
    # ENV, otherwise the ENABLED constant (default false).
    def enabled?
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
    def run(db)
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

    # Provide the Kernel methods the scripts assume the player supplies:
    #   load_data(filename)      -> Marshal.load of a project file
    #   save_data(obj, filename) -> Marshal.dump of a project file
    # routed through the database so a loose file and the encrypted archive both
    # work. Defined on Object so a script can call them bare; guarded so a second
    # boot does not redefine them.
    def install_kernel(db)
      return if Object.method_defined?(:load_data) ||
                Object.private_method_defined?(:load_data)
      Object.class_eval do
        define_method(:load_data) { |filename| db.read_object(filename) }
        define_method(:save_data) { |obj, filename| db.save_object(obj, filename) }
        private :load_data, :save_data
      end
    end
  end
end
