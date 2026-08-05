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
# It was built as the alternative to that reimplementation (see
# docs/adr/0017-rpgxp-rgss-script-host.md) and is now the **default** path
# (docs/adr/0029-rgss-script-host-by-default.md): a project that ships scripts
# ships its own engine, so running them is what running the game means. The
# built-in flow stays as the fallback — for a project that ships no scripts, when
# the host fails to boot, and whenever the opt-out (RGSS_SCRIPT_HOST=0) is set.
# `Kernel#eval` comes from the core mruby-eval gem, a hard dependency of this gem
# (mruby-rpgxp/mrbgem.rake).
class RPGXP
  # Defined with explicit `def self.` singleton methods (not a bare
  # `module_function`, which this mruby build does not apply to later defs) so
  # the host is callable as RPGXP::ScriptHost.<method>.
  module ScriptHost
    # Environment variable that switches the script host off. The host is on by
    # default, so this is an *opt-out*: set RGSS_SCRIPT_HOST to one of
    # DISABLED_VALUES to boot the built-in reimplemented flow instead (what the
    # headless render checks compare against, and the escape hatch for a project
    # whose scripts the host cannot yet run). The native binary spells the same
    # switch --norgss_script_host.
    ENABLED_ENV = "RGSS_SCRIPT_HOST".freeze

    # The values that turn the host *off*, compared literally in lower case (no
    # String#downcase, which this mruby build is not known to carry — the same
    # reason the rest of this gem sticks to the common subset). Anything else —
    # including "1" — leaves the host on. src/main.cxx carries the same list for
    # the environment variable it reads on the Ruby side's behalf; keep them
    # together.
    DISABLED_VALUES = ["0", "false", "off", "no"].freeze

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

    # Whether to run the bundled scripts instead of the built-in flow. **On by
    # default**: an RGSS project's scripts *are* its engine, so running them is
    # the faithful boot; the built-in reimplementation is the fallback for a
    # project that ships none, and for a host that cannot get the game's own
    # engine up. Only an explicit opt-out turns it off, from either of two
    # places, because the two runtimes read their settings differently:
    #
    # **The `--rgss_script_host` flag** is the switch that works in a built
    # engine. src/main.cxx publishes it as the RGSS_SCRIPT_HOST constant, the way
    # it publishes `--rpgxp_new_game` as RPGXP_NEW_GAME, and it is read through
    # its own rescue because an undefined constant raises here (this mruby has no
    # `defined?(CONST)`). It also folds in the environment variable below, which
    # a booted game cannot read for itself.
    #
    # **The RGSS_SCRIPT_HOST environment variable** is what every document used
    # to name, and on its own it could never have switched the host: this mruby
    # build has no ENV at all, so the check below was simply never reached in the
    # engine. Only the CRuby harnesses — where ENV does exist — ever saw it work,
    # which is why the dead switch went unnoticed. It is still honoured, for them.
    #
    # With neither present — an embedded target, or a host-side unit test — the
    # default stands.
    def self.enabled?
      setting = flag_setting
      return setting unless setting.nil?
      return true unless Object.const_defined?(:ENV)
      flag = ENV[ENABLED_ENV]
      # Unset or empty is "not asked for either way" — the default wins.
      return true if flag.nil? || flag.empty?
      !DISABLED_VALUES.include?(flag)
    end

    # The RGSS_SCRIPT_HOST constant the native binary publishes, or nil where
    # there is none (the CRuby harnesses, mrbtest, an embedded build) — nil is
    # "nothing said", which is why this cannot just answer true/false.
    def self.flag_setting
      RGSS_SCRIPT_HOST
    rescue StandardError
      nil
    end

    # Run the project's bundled scripts to completion. `db` answers #scripts
    # (an ordered array of [name, source]) and #read_object / #save_object for
    # the Kernel built-ins. Returns true when the scripts were run, false when
    # the project ships none, so the caller can fall back to the built-in flow.
    # Evaluating "Main" blocks here until the game's own loop exits, exactly as
    # RGSS does.
    def self.run(db)
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
      # A machine-readable marker, the script-host twin of the built-in flow's
      # [RPGXP-MAP]: it is what a headless run (scripts/rpgxp_boot_check.bash)
      # asserts on to prove the host — not the built-in flow — booted the game.
      $stderr.puts "[RPGXP-SCRIPTS] running #{sections.size} script sections"
      sections.each do |name, source|
        # Evaluate through the top-level helper so a section's `class Scene_Title`
        # etc. define global (::) constants, as under RGSS — see rgss_eval_section.
        #
        # Name the section in the failure. The host is how a game's own engine
        # runs, so a boot failure is a report about which part of the RGSS class
        # library is still missing (docs/rpgxp-rgss-api-gap.md) — and "NameError:
        # uninitialized constant RPG::Sprite" says nothing about *where* to look
        # without it. Re-raised, so the caller still falls back to the built-in
        # flow.
        begin
          rgss_eval_section(source, name)
        rescue StandardError, ScriptError => e
          $stderr.puts "[RGSS] script host: section #{name.inspect} raised " \
                       "#{e.class}: #{e.message}"
          # `raise` with no argument loses the exception in this mruby build
          # (the caller saw a bare RuntimeError), so re-raise it explicitly.
          raise e
        end
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
