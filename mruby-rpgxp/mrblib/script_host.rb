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

    # True while the host's blocking `Main` runs inside the driver Fiber (see
    # RPGXP#setup_script_host_driver). The wrapped Graphics.update reads this to
    # decide whether to yield the fiber once per frame — so the flag is only ever
    # set on the script-host path and the built-in flow never yields. See
    # docs/adr/0023-rpgxp-script-host-frame-driver.md.
    @driving = false
    def self.driving?
      @driving
    end

    def self.driving=(v)
      @driving = v
    end

    # Whether the runtime can eval Ruby source at all (mruby-eval present, or
    # CRuby). Kernel#eval is a public method under mruby-eval and a private one
    # under CRuby; the private check is itself CRuby-only (mruby's Module has no
    # private_method_defined?), so guard it with respond_to?.
    def self.available?
      return true if Kernel.method_defined?(:eval)
      Kernel.respond_to?(:private_method_defined?) &&
        Kernel.private_method_defined?(:eval)
    end

    # Whether to run the bundled scripts instead of the built-in flow: requires
    # eval support and an explicit opt-in via the RGSS_SCRIPT_HOST env var (when
    # the runtime exposes ENV). Off by default. Uses const_defined? rather than
    # defined?(CONST), which raises on an undefined constant in this mruby build.
    def self.enabled?
      return false unless available?
      return false unless Object.const_defined?(:ENV)
      flag = ENV[ENABLED_ENV]
      !(flag.nil? || flag.empty? || flag == "0" || flag == "false")
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
      sections.each do |name, source|
        # Evaluate through the top-level helper so a section's `class Scene_Title`
        # etc. define global (::) constants, as under RGSS — see rgss_eval_section.
        rgss_eval_section(source, name)
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

    # Build the per-frame driver Fiber for a project's bundled scripts. The
    # scripts own their whole blocking main loop, so it runs inside a Fiber that
    # the wrapped Graphics.update below yields once per frame — the caller then
    # resumes it once per frame (see RPGXP#drive_script_host / RPGVX). Shared by
    # every RGSS maker's boot shell; see
    # docs/adr/0023-rpgxp-script-host-frame-driver.md.
    def self.build_driver(db)
      install_graphics_yield
      Fiber.new do
        self.driving = true
        begin
          run(db)
        ensure
          self.driving = false
        end
      end
    end

    # Wrap the native Graphics.update so a scene's `loop { Graphics.update; ... }`
    # yields the driver Fiber once per frame. Idempotent, and installed only on
    # the script-host path — a built-in flow keeps the pristine native method.
    def self.install_graphics_yield
      return if RGSS::Graphics.respond_to?(:_update_native)
      RGSS::Graphics.singleton_class.class_eval do
        alias_method :_update_native, :update
        def update
          _update_native
          Fiber.yield if ::RPGXP::ScriptHost.driving?
        end
      end
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

# Evaluate one RGSS script section. Defined at the TOP LEVEL (not inside
# RPGXP::ScriptHost) on purpose: mruby resolves `class Foo` in eval'd code
# against the *lexical* scope of the method that calls eval, so evaluating from
# inside a module would define the section's classes under that module. Called
# from here, the lexical scope is Object, so `class Scene_Title` etc. become
# global (::) constants — matching how RGSS evaluates the scripts at top level.
# CRuby is handled the same way via TOPLEVEL_BINDING when present (mruby has no
# such constant and a nil-binding eval here already targets the top level);
# const_defined? avoids defined?(CONST), which raises on an unknown constant in
# this mruby build. The section name becomes the "file" in any backtrace.
def rgss_eval_section(source, name)
  top = Object.const_defined?(:TOPLEVEL_BINDING) ? TOPLEVEL_BINDING : nil
  eval(source, top, name, 1)
end
