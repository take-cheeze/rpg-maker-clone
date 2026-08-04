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

  # Load order matters: lib.rb defines the RPGXP class and its WIDTH/HEIGHT/TILE
  # constants (and pulls RGSS into Object), which the scene/game sources read at
  # class-body evaluation time. Set the order explicitly rather than relying on
  # the default alphabetical glob.
  spec.rbfiles = %w[lib rgss_data script_host rgssad game interpreter scene].map do |name|
    "#{dir}/mrblib/#{name}.rb"
  end
end
