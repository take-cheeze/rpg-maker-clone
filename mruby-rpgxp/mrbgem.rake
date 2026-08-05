MRuby::Gem::Specification.new('mruby-rpgxp') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RPG Maker XP (RGSS) runtime'

  add_dependency 'mruby-rgss'
  add_dependency 'mruby-io'
  # RGSSAD archive decoding assembles decrypted bytes with Array#pack("C*").
  add_dependency 'mruby-pack'
  # The RGSS script host (script_host.rb) runs the game's bundled Ruby scripts
  # with Kernel#eval.
  add_dependency 'mruby-eval'
  # The script-host driver runs the scripts' blocking main loop inside a Fiber
  # (docs/adr/0023-rpgxp-script-host-frame-driver.md).
  add_dependency 'mruby-fiber'
  # Kernel#exit / SystemExit — the stock Interpreter calls `exit` to abort on
  # runaway common-event recursion; the driver ends the game on it.
  add_dependency 'mruby-exit'
  # Kernel#sprintf / #format and String#% (used by the stock RGSS scripts, and by
  # the sprintf availability test). It is also enabled in build_config.rb, but
  # declaring the dependency here forces mruby-sprintf to initialize before this
  # gem: without the edge, gem init order left Kernel#sprintf undefined when the
  # host loaded, so the scripts' "%02d"/"%04d" formatting raised NoMethodError.
  add_dependency 'mruby-sprintf'
  # Kernel#Integer(), which every game's Game_Battler_1 clamps its stats with.
  # Declared here for the same reason as mruby-sprintf above: the dependency edge
  # is what orders its initialization before this gem.
  add_dependency 'mruby-kernel-ext'
  # Kernel#rand, which a game's scripts roll for encounters and damage variance
  # (and RPG::Weather for its drops). Same ordering reason.
  add_dependency 'mruby-random'
  # Numeric#zero?, which a game's own scripts use. Same story as mruby-sprintf
  # above: it is enabled in build_config.rb, but without the dependency edge to
  # order its initialization before this gem the method was undefined in the
  # `rake test` binary — `undefined method 'zero?' for Integer`, in CI only, with
  # the full game build working. See the "mruby stdlib methods live in core
  # *-ext mrbgems" note in AGENTS.md.
  add_dependency 'mruby-numeric-ext'
  # Math.sqrt, which the *stock* Game_Character#jump measures its jump distance
  # with — so every RMXP game reaches it the first time an event or a move route
  # jumps, not just the ones with unusual scripts. Same ordering reason.
  add_dependency 'mruby-math'
  # Time, which the stock save/load screens compare slot timestamps with
  # (`Time.at(0)`, `File#mtime`). Same ordering reason.
  add_dependency 'mruby-time'

  # Load order matters: lib.rb defines the RPGXP class and its WIDTH/HEIGHT/TILE
  # constants and pulls RGSS into Object, which the sources after it read at
  # class-body evaluation time. rgss_library then defines RPG::Sprite (a subclass
  # of the native RGSS::Sprite), which the script host evaluates a game's own
  # scripts against. Set the order explicitly rather than relying on the default
  # alphabetical glob.
  spec.rbfiles = %w[lib rgss_data rgss_library script_host rgssad].map do |name|
    "#{dir}/mrblib/#{name}.rb"
  end
end
