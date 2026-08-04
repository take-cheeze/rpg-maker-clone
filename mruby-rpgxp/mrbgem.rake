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
  # Kernel#sprintf / #format and String#% (used by the stock RGSS scripts, and by
  # the sprintf availability test). It is also enabled in build_config.rb, but
  # declaring the dependency here forces mruby-sprintf to initialize before this
  # gem: without the edge, gem init order left Kernel#sprintf undefined when the
  # host loaded, so the scripts' "%02d"/"%04d" formatting raised NoMethodError.
  add_dependency 'mruby-sprintf'

  # Load order matters: lib.rb defines the RPGXP class and its WIDTH/HEIGHT/TILE
  # constants (and pulls RGSS into Object), which the scene/game sources read at
  # class-body evaluation time. Set the order explicitly rather than relying on
  # the default alphabetical glob.
  spec.rbfiles = %w[lib rgss_data script_host rgssad game interpreter scene].map do |name|
    "#{dir}/mrblib/#{name}.rb"
  end
end
